# frozen_string_literal: true

module RecordingStudioBilling
  class PaymentsPresenter < BasePresenter
    attr_accessor :payments, :refunds, :refund_intents

    def page = :payments

    def payment_state(payment)
      payment.financial_command&.state || payment.state
    end

    def payment_details(payment)
      display_value(payment[:safe_snapshot])
    end

    def refund_status(refund)
      refund.financial_command.state
    end
  end
end
