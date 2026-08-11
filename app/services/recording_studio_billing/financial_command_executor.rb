# frozen_string_literal: true

module RecordingStudioBilling
  class FinancialCommandExecutor
    class WorkerCrash < Exception; end

    def self.call(adapter:, lease_duration: FinancialCommandClaim::DEFAULT_LEASE, after_adapter_call: nil,
            **command_attributes)
      reject_ambient_transaction!
      adapter.validate!(request: command_attributes.fetch(:request)) if adapter.respond_to?(:validate!)
      creation = nil
      claim = nil
      FinancialCommand.transaction do
        creation = CreateFinancialCommand.call(**command_attributes)
        claim = FinancialCommandClaim.call(command: creation.command, lease_duration:) if creation.created?
      end
      return creation unless creation.created?

      new(command: creation.command, adapter:, after_adapter_call:).execute(claim:)
      creation
    end

    def self.execute(command:, adapter:, after_adapter_call: nil)
      reject_ambient_transaction!
      claim = FinancialCommandClaim.call(command:)
      return command unless claim

      new(command:, adapter:, after_adapter_call:).execute(claim:)
    end

    def self.reject_ambient_transaction!
      return unless ActiveRecord::Base.connection.transaction_open?

      raise ArgumentError, "financial commands cannot execute inside an open database transaction"
    end

    def initialize(command:, adapter:, after_adapter_call: nil)
      @command = command
      @adapter = adapter
      @after_adapter_call = after_adapter_call
    end

    def execute(claim:)
      attempt = claim.attempt
      FinancialCommand.transaction do
        command.lock!
        verify_claim!(claim)
      end
      response = adapter.call(
        command: command,
        request: command.canonical_request,
        idempotency_key: command.provider_idempotency_key
      )
      after_adapter_call&.call(command, response)
      persist_response!(claim, response)
      command.reload
    rescue StandardError => error
      persist_uncertain_error!(claim, error) if claim
      raise
    end

    private

    attr_reader :adapter, :after_adapter_call, :command

    def persist_response!(claim, response)
      normalized = normalize_response(response)
      FinancialCommand.transaction do
        command.lock!
        verify_claim!(claim)
        attempt = claim.attempt.reload
        attempt.update!(
          state: normalized.fetch(:attempt_state),
          completed_at: Time.current,
          normalized_result: normalized.fetch(:result),
          safe_error_details: normalized.fetch(:error_details),
          uncertain_outcome: normalized.fetch(:uncertain_outcome),
          safe_metadata: normalized.fetch(:metadata)
        )
        command.update!(
          state: normalized.fetch(:command_state),
          provider_reference: normalized.fetch(:provider_reference),
          normalized_result: normalized.fetch(:result),
          safe_error_details: normalized.fetch(:error_details),
          reconciliation_state: normalized.fetch(:reconciliation_state),
          claim_token: nil, claimed_at: nil, lease_expires_at: nil
        )
      end
    end

    def normalize_response(response)
      raise ArgumentError, "adapter response must be an object" unless response.is_a?(Hash)

      response = response.transform_keys(&:to_sym)
      requested_state = response.fetch(:state).to_s
      terminal_states = %w[succeeded failed uncertain requires_reconciliation cancelled]
      pending = requested_state == "pending"
      unknown_state = !terminal_states.include?(requested_state) && !pending
      uncertain = response.fetch(:uncertain_outcome, false) || unknown_state || requested_state == "uncertain"
      command_state = uncertain || pending ? "requires_reconciliation" : requested_state
      attempt_state = pending ? "requires_reconciliation" : (uncertain ? "uncertain" : requested_state)
      result = SafeFinancialPayload.normalize(response.fetch(:normalized_result, {}))
      result["status"] = uncertain ? "unknown" : requested_state
      provider_reference = response[:provider_reference]
      unless provider_reference.nil? || (provider_reference.is_a?(String) && provider_reference.bytesize <= 512)
        raise ArgumentError, "provider reference must be a bounded string"
      end

      {
        command_state:,
        attempt_state:,
        result:,
        error_details: SafeFinancialPayload.normalize(response.fetch(:safe_error_details, {})),
        metadata: SafeFinancialPayload.normalize(response.fetch(:safe_metadata, {})),
        uncertain_outcome: uncertain,
        provider_reference:,
        reconciliation_state: uncertain || pending || requested_state == "requires_reconciliation" ? "pending" : "not_required"
      }
    end

    def persist_uncertain_error!(claim, error)
      details = { "error_class" => error.class.name }
      FinancialCommand.transaction do
        command.lock!
        return unless current_claim?(claim)

        attempt = claim.attempt.reload
        attempt.update!(
          state: "uncertain", completed_at: Time.current, uncertain_outcome: true,
          safe_error_details: details
        )
        command.update!(
          state: "requires_reconciliation", reconciliation_state: "pending",
          safe_error_details: details, claim_token: nil, claimed_at: nil, lease_expires_at: nil
        )
      end
    end

    def verify_claim!(claim)
      raise ArgumentError, "financial command claim is no longer current" unless current_claim?(claim)
    end

    def current_claim?(claim)
      command.state == "processing" && command.claim_token == claim.token &&
        claim.attempt.state == "processing" && claim.attempt.completed_at.nil? && lease_live_in_database?(claim)
    end

    def lease_live_in_database?(claim)
      FinancialCommand.connection.select_value(
        FinancialCommand.sanitize_sql_array([
          "SELECT lease_expires_at > CURRENT_TIMESTAMP FROM recording_studio_billing_financial_commands " \
          "WHERE id = ? AND claim_token = ? AND state = 'processing'",
          command.id, claim.token
        ])
      ) == true
    end
  end
end