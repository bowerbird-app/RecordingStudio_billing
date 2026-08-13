# frozen_string_literal: true

module RecordingStudioBilling
  class FinancialCommandExecutor
    class WorkerCrash < StandardError; end

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
      raise ArgumentError, "provider adapter key does not match the financial command" unless command.provider_adapter_key == adapter_key

      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(adapter_key)
      execute_with_adapter(command:, adapter:, after_adapter_call:, capability_requirements:)
    end

    def self.execute_tax(command:)
      calculator = RecordingStudioBilling.configuration.tax_calculator_registry.fetch(command.calculator_key)
      execute_with_adapter(command:, adapter: CalculateTax::ValidatingAdapter.new(calculator))
    end

    def self.execute_with_adapter(command:, adapter:, after_adapter_call: nil, capability_requirements: {})
      reject_ambient_transaction!
      return command if subscription_change_not_due?(command)

      claim = FinancialCommandClaim.call(command:)
      return command unless claim

      new(command:, adapter:, after_adapter_call:, capability_requirements:).execute(claim:)
    end

    def self.subscription_change_not_due?(command)
      return false unless command.command_type == "subscription_change"

      effective_at = command.canonical_request.dig("request", "effective_at")
      effective_at.present? && Time.iso8601(effective_at).future?
    rescue ArgumentError
      true
    end

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
      claim.attempt
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
    rescue StandardError => e
      persist_uncertain_error!(claim, e) if claim
      raise
    end

    private

    attr_reader :adapter, :after_adapter_call, :capability_requirements, :command

    def capability_response
      requirements = request_capability_requirements.merge(capability_requirements)
      return if requirements.empty?

      evaluation = adapter.capabilities.evaluate(**requirements)
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

    def request_capability_requirements
      request = command.canonical_request.fetch("request", {}).to_h.stringify_keys
      case command.command_type
      when "checkout"
        {
          operations: "checkout",
          currencies: request["currency"],
          collection_methods: request["collection_method"],
          checkout_modes: request["presentation"]
        }.compact
      when "subscription_change"
        {
          operations: "subscription_change",
          subscription_change_kinds: request["change_kind"]
        }.compact
      else
        {}
      end
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
        create_provider_reference!(normalized.fetch(:provider_reference)) if persist_provider_reference?(normalized)
        record_subscription_change_outcome!(normalized)
      end
    end

    def record_subscription_change_outcome!(normalized)
      return unless command.command_type == "subscription_change"

      state = case normalized.fetch(:command_state)
              when "failed", "cancelled" then "failed"
              when "uncertain", "requires_reconciliation" then "requires_review"
              end
      return unless state

      SubscriptionChangeIntent.where(financial_command: command).lock.find_each do |intent|
        next unless %w[pending_provider scheduled].include?(intent.state)

        intent.update!(state:, outcome: intent.outcome.merge("provider_result" => normalized.fetch(:result)))
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
      attempt_state = if pending
                        "requires_reconciliation"
                      else
                        (uncertain ? "uncertain" : requested_state)
                      end
      result = SafeFinancialPayload.normalize(response.fetch(:normalized_result, {}))
      result["status"] = uncertain ? "unknown" : requested_state
      provider_reference = response[:provider_reference]
      raise ArgumentError, "provider reference must be a bounded string" unless provider_reference.nil? || (provider_reference.is_a?(String) && provider_reference.bytesize <= 512)

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

    def create_provider_reference!(provider_reference)
      return unless provider_reference
      return unless adapter.respond_to?(:provider_reference_type)

      remote_type = adapter.provider_reference_type(command:, provider_reference:)
      return unless remote_type

      ProviderReference.find_or_create_by!(
        provider_adapter_key: command.provider_adapter_key,
        provider_account_recording_id: command.provider_account_recording_id,
        environment: command.provider_account_recording.recordable.environment,
        remote_type: remote_type.to_s,
        remote_id: provider_reference
      ) do |reference|
        reference.financial_command = command
        reference.reference = provider_reference
        reference.reference_type = remote_type.to_s
      end
    end

    def persist_provider_reference?(normalized)
      reference = normalized.fetch(:provider_reference)
      return false unless reference && adapter.respond_to?(:provider_reference_type)

      normalized.fetch(:command_state) == "succeeded" ||
        (command.command_type == "checkout" && adapter.provider_reference_type(command:,
                                                                               provider_reference: reference).present?)
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
      attempt_state = if status == "pending"
                        "requires_reconciliation"
                      else
                        (uncertain ? "uncertain" : command_state)
                      end

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
