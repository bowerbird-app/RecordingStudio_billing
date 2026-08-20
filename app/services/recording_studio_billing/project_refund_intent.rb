# frozen_string_literal: true

module RecordingStudioBilling
  class ProjectRefundIntent
    def self.call(refund_intent:, root_recording:) = new(refund_intent:, root_recording:).call

    def initialize(refund_intent:, root_recording:)
      @refund_intent_input = refund_intent
      @root_recording_input = root_recording
    end

    def call
      result = RefundIntent.transaction do
        intent = RefundIntent.where(root_recording: RecordingStudio.root_recording_or_self(root_recording_input)).lock.find(intent_id)
        return intent.refund if intent.refund

        command = intent.financial_command
        raise ArgumentError, "refund command has not completed" unless command&.state == "succeeded"

        result = command.normalized_result
        unless provider_result_matches?(intent, command, result)
          reconcile!(command, intent, result)
          next :requires_reconciliation
        end

        refund = Refund.create!(refund_intent: intent, payment: intent.payment, financial_command: command,
                                amount_minor: result.fetch("amount_minor"), currency_code: result.fetch("currency"),
                                provider_reference: result.fetch("provider_reference"), recorded_at: Time.current,
                                safe_snapshot: { "refund_intent_id" => intent.id, "payment_id" => intent.payment_id,
                                                 "provider_result" => result })
        intent.update!(state: "completed")
        refund
      end
      raise ArgumentError, "refund provider result requires reconciliation" if result == :requires_reconciliation

      result
    end

    private

    attr_reader :refund_intent_input, :root_recording_input

    def intent_id = refund_intent_input.respond_to?(:id) ? refund_intent_input.id : refund_intent_input

    def provider_result_matches?(intent, command, result)
      result["status"].in?(%w[success duplicate]) && result["amount_minor"] == intent.amount_minor &&
        result["currency"] == intent.currency_code && result["payment_id"] == intent.payment_id &&
        result["provider_account_recording_id"] == command.provider_account_recording_id && result["provider_reference"].present?
    end

    def reconcile!(command, intent, result)
      ReconciliationIssue.find_or_create_by!(financial_command: command, authority: "refund_projection",
                                             kind: "provider_result_mismatch") do |issue|
        issue.state = "open"
        issue.safe_payload = { "refund_intent_id" => intent.id, "requested_amount_minor" => intent.amount_minor,
                               "requested_currency" => intent.currency_code, "provider_result" => result }
      end
    end
  end
end
