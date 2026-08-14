# frozen_string_literal: true

module RecordingStudioBilling
  class InvoicePresenter < BasePresenter
    attr_accessor :invoice, :adjustments, :refunds, :payments

    def page = :invoice

    def snapshot_rows
      (invoice[:safe_snapshot] || {}).map { |key, value| [key.to_s.humanize, display_value(value)] }
    end

    def command_state
      invoice.financial_command&.state
    end

    def financial_rows
      Array(payments).map { |payment| "Payment #{display_amount(payment.amount_minor, payment.currency_code)}: #{payment.financial_command&.state || payment.state}" } +
        Array(refunds).map { |refund| "Refund #{display_amount(refund.amount_minor, refund.currency_code)}: #{refund.financial_command.state}" } +
        Array(adjustments).map { |adjustment| "#{adjustment.kind.humanize} #{display_amount(adjustment.amount_minor, adjustment.currency_code)}: #{adjustment.financial_command.state}" }
    end
  end
end
