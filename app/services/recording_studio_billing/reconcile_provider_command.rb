# frozen_string_literal: true

module RecordingStudioBilling
  class ReconcileProviderCommand
    KNOWN_OUTCOMES = %w[succeeded failed].freeze

    def self.call(command:)
      command.reload
      return command if command.state.in?(%w[failed cancelled])
      return command if command.state == "succeeded" && command.command_type != "checkout"
      return command if command.state == "succeeded" && checkout_result_authoritative?(command)

      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(command.provider_adapter_key)
      unless adapter.respond_to?(:retrieve)
        raise ArgumentError,
              "provider adapter does not support reconciliation retrieval"
      end

      response = retrieve_response(adapter, command)
      return command if response.nil?
      raise ArgumentError, "provider reconciliation response must be a Hash" unless response.is_a?(Hash)

      reconcile(command:, response: response.to_h)
    rescue KeyError => e
      record_unavailable(command, e)
    end

    def self.checkout_result_authoritative?(command)
      result = command.normalized_result
      %w[subtotal_minor discount_minor tax_minor total_minor currency lines].all? { |key| result.key?(key) }
    end
    private_class_method :checkout_result_authoritative?

    def self.retrieve_response(adapter, command)
      adapter.retrieve(command: command.reload)
    rescue ArgumentError => e
      record_unavailable(command, e)
      nil
    end
    private_class_method :retrieve_response

    def self.reconcile(command:, response:)
      FinancialCommand.transaction do
        command.lock!
        response = response.stringify_keys
        keys = response.keys.sort
        allowed = %w[outcome payload remote_id remote_type]
        raise ArgumentError, "provider reconciliation response has unsupported keys" unless (keys - allowed).empty?

        outcome = response.fetch("outcome").to_s
        payload = response.fetch("payload")
        raise ArgumentError, "provider reconciliation response payload must be an object" unless payload.is_a?(Hash)

        normalized_result = SafeFinancialPayload.normalize(payload,
                                                           allow_authoritative_totals: command.command_type == "checkout")
        remote_type = response.fetch("remote_type")
        remote_id = response.fetch("remote_id")
        ProviderReference.find_by!(financial_command: command, provider_adapter_key: command.provider_adapter_key,
                                   remote_type:, remote_id:)
        return command if command.state.in?(%w[succeeded failed cancelled])

        record = reconciliation_record(command, outcome:, payload: {
                                         "remote_type" => remote_type, "remote_id" => remote_id, "normalized_result" => normalized_result
                                       })

        unless KNOWN_OUTCOMES.include?(outcome)
          ReconciliationIssue.find_or_create_by!(financial_command: command, kind: "unknown_provider_state",
                                                 authority: "provider") do |issue|
            issue.safe_payload = SafeFinancialPayload.normalize(payload)
          end
          command.update!(state: "requires_reconciliation", reconciliation_state: "pending",
                          normalized_result: normalized_result.merge("status" => "unknown", "outcome" => outcome))
          return record
        end

        state = outcome == "succeeded" ? "succeeded" : "failed"
        command.update!(state:, reconciliation_state: "reconciled",
                        normalized_result: normalized_result.merge("status" => outcome, "outcome" => outcome))
        if state == "succeeded" && command.command_type == "checkout"
          CheckoutIntent.where(financial_command: command).update_all(state: "awaiting_confirmation",
                                                                      updated_at: Time.current)
        end
        record
      end
    end

    def self.record_unavailable(command, _error)
      FinancialCommand.transaction do
        command.lock!
        return command if command.state.in?(%w[succeeded failed cancelled])

        record = reconciliation_record(command, outcome: "unavailable", payload: {})

        ReconciliationIssue.find_or_create_by!(financial_command: command, kind: "reconciliation_unavailable",
                                               authority: "provider") do |issue|
          issue.safe_payload = {}
        end
        command.update!(state: "requires_reconciliation", reconciliation_state: "pending")
        record
      end
    end

    def self.reconciliation_record(command, outcome:, payload:)
      ReconciliationRecord.lock.find_by(financial_command: command, authority: "provider") ||
        ReconciliationRecord.create!(financial_command: command, authority: "provider", outcome:,
                                     safe_payload: SafeFinancialPayload.normalize(
                                       payload, allow_authoritative_totals: command.command_type == "checkout"
                                     ))
    end
    private_class_method :reconcile, :record_unavailable, :reconciliation_record
  end
end
