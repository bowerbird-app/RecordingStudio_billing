# frozen_string_literal: true

module RecordingStudioBilling
  class FinancialCommandExecutor
    class WorkerCrash < Exception; end

    def self.call(provider_key:, lease_duration: FinancialCommandClaim::DEFAULT_LEASE, after_adapter_call: nil,
                  capability_requirements: {}, **command_attributes)
      adapter_key = provider_key.to_s
      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(adapter_key)
      call_with_adapter(
        adapter:, lease_duration:, after_adapter_call:, capability_requirements:,
        **command_attributes.merge(provider_adapter_key: adapter_key)
      )
    end

    def self.call_tax(calculator_key:, lease_duration: FinancialCommandClaim::DEFAULT_LEASE, **command_attributes)
      calculator = RecordingStudioBilling.configuration.tax_calculator_registry.fetch(calculator_key)
      call_with_adapter(
        adapter: CalculateTax::ValidatingAdapter.new(calculator), lease_duration:,
        **command_attributes.merge(calculator_key: calculator_key.to_s)
      )
    end

    def self.call_with_adapter(adapter:, lease_duration:, after_adapter_call: nil, capability_requirements: {},
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

      new(command: creation.command, adapter:, after_adapter_call:, capability_requirements:).execute(claim:)
      creation
    end

    def self.execute(command:, provider_key:, after_adapter_call: nil, capability_requirements: {})
      adapter_key = provider_key.to_s
      unless command.provider_adapter_key == adapter_key
        raise ArgumentError, "provider adapter key does not match the financial command"
      end

      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(adapter_key)
      execute_with_adapter(command:, adapter:, after_adapter_call:, capability_requirements:)
    end

    def self.execute_tax(command:)
      calculator = RecordingStudioBilling.configuration.tax_calculator_registry.fetch(command.calculator_key)
      execute_with_adapter(command:, adapter: CalculateTax::ValidatingAdapter.new(calculator))
    end

    def self.execute_with_adapter(command:, adapter:, after_adapter_call: nil, capability_requirements: {})
      reject_ambient_transaction!
      claim = FinancialCommandClaim.call(command:)
      return command unless claim

      new(command:, adapter:, after_adapter_call:, capability_requirements:).execute(claim:)
    end

    private_class_method :call_with_adapter, :execute_with_adapter

    def self.reject_ambient_transaction!
      return unless ActiveRecord::Base.connection.transaction_open?

      raise ArgumentError, "financial commands cannot execute inside an open database transaction"
    end

    def initialize(command:, adapter:, after_adapter_call: nil, capability_requirements: {})
      @command = command
      @adapter = adapter
      @after_adapter_call = after_adapter_call
      @capability_requirements = capability_requirements
    end

    def execute(claim:)
      attempt = claim.attempt
      FinancialCommand.transaction do
        command.lock!
        verify_claim!(claim)
      end
      response = capability_response || adapter.call(
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

    attr_reader :adapter, :after_adapter_call, :capability_requirements, :command

    def capability_response
      return if capability_requirements.empty?

      evaluation = adapter.capabilities.evaluate(**capability_requirements)
      return if evaluation.supported?

      AdapterResponse.new(
        status: normalized_unsupported_status(evaluation.reason),
        result: { "reason" => evaluation.reason, "explanation" => evaluation.explanation,
                  "constraints" => evaluation.constraints }
      )
    end

    def normalized_unsupported_status(reason)
      AdapterResponse::STATUSES.include?(reason) ? reason : "unsupported"
    end

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
      return normalize_adapter_response(response) if response.is_a?(AdapterResponse)

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
      provider_reference = SafeFinancialPayload.normalize_reference(provider_reference, label: "provider reference") unless provider_reference.nil?

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

    def normalize_adapter_response(response)
      status = response.status
      uncertain = response.uncertain_outcome || %w[pending unknown].include?(status)
      successful = %w[success duplicate].include?(status)
      requires_reconciliation = uncertain || status == "requires_review"
      command_state = if requires_reconciliation
                        "requires_reconciliation"
                      elsif successful
                        "succeeded"
                      else
                        "failed"
                      end
      attempt_state = status == "pending" ? "requires_reconciliation" : (uncertain ? "uncertain" : command_state)

      {
        command_state:,
        attempt_state:,
        result: response.result,
        error_details: response.error_details,
        metadata: response.metadata,
        uncertain_outcome: uncertain,
        provider_reference: response.provider_reference,
        reconciliation_state: requires_reconciliation ? "pending" : "not_required"
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