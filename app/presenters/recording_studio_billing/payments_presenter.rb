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

    def refund_status(refund)
      money_state(refund.financial_command.state)
    end
  end
end
