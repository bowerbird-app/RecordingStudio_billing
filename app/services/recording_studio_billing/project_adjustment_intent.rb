# frozen_string_literal: true

module RecordingStudioBilling
  class ProjectAdjustmentIntent
    def self.call(adjustment_intent:, root_recording:) = new(adjustment_intent:, root_recording:).call

    def initialize(adjustment_intent:, root_recording:)
      @adjustment_intent_input = adjustment_intent
      @root_recording_input = root_recording
    end

    def call
      result = AdjustmentIntent.transaction do
        intent = AdjustmentIntent.where(root_recording: RecordingStudio.root_recording_or_self(root_recording_input)).lock.find(intent_id)
        return intent.financial_adjustment if intent.financial_adjustment

        command = intent.financial_command
        raise ArgumentError, "adjustment command has not completed" unless command&.state == "succeeded"

        result = command.normalized_result
        unless provider_result_matches?(intent, command, result)
          reconcile!(command, intent, result)
          next :requires_reconciliation
        end

        adjustment = FinancialAdjustment.create!(adjustment_intent: intent, invoice: intent.invoice, financial_command: command,
                                                 kind: result.fetch("kind"), amount_minor: result.fetch("amount_minor"), currency_code: result.fetch("currency"),
                                                 recorded_at: Time.current, safe_snapshot: { "adjustment_intent_id" => intent.id,
                                                                                             "invoice_id" => intent.invoice_id, "provider_result" => result })
        intent.update!(state: "completed")
        adjustment
      end
      raise ArgumentError, "adjustment provider result requires reconciliation" if result == :requires_reconciliation

      result
    end

    private

    attr_reader :adjustment_intent_input, :root_recording_input

    def intent_id = adjustment_intent_input.respond_to?(:id) ? adjustment_intent_input.id : adjustment_intent_input

    def provider_result_matches?(intent, command, result)
      result["status"].in?(%w[success duplicate]) && result["kind"] == intent.kind &&
        result["amount_minor"] == intent.amount_minor && result["currency"] == intent.currency_code &&
        result["invoice_id"] == intent.invoice_id && result["provider_account_recording_id"] == command.provider_account_recording_id &&
        result["provider_reference"].present?
    end

    def reconcile!(command, intent, result)
      ReconciliationIssue.find_or_create_by!(financial_command: command, authority: "adjustment_projection",
                                             kind: "provider_result_mismatch") do |issue|
        issue.state = "open"
        issue.safe_payload = { "adjustment_intent_id" => intent.id, "requested_kind" => intent.kind,
                               "requested_amount_minor" => intent.amount_minor, "provider_result" => result }
      end
    end
  end
end
