# frozen_string_literal: true

module RecordingStudioBilling
  class PaymentsPresenter < BasePresenter
    attr_accessor :payments, :refunds, :refund_intents

    def page = :payments

    def payment_state(payment)
      money_state(payment.financial_command&.state || payment.state)
    end

    def payment_summary(payment)
      snapshot = payment[:safe_snapshot] || {}
      source = snapshot["source"] || snapshot[:source]
      return copy("payment_source_card", "Paid by card") if source.to_s == "card"

      nil
    end

    def payment_recorded_at(payment)
      payment.try(:recorded_at)&.to_fs(:long)
    end

    def refund_status(refund)
      money_state(refund.financial_command.state)
    end

    def pending_refund_rows
      Array(refund_intents).reject { |intent| intent.try(:refund) }.map do |intent|
        {
          label: copy("refund_title", "Refund"),
          amount: display_amount(intent.amount_minor, intent.currency_code),
          status: money_state(intent.financial_command&.state || intent.state)
        }
      end
    end
  end
end
