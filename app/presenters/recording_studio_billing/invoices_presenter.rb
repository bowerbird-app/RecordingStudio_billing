# frozen_string_literal: true

module RecordingStudioBilling
  class InvoicesPresenter < BasePresenter
    attr_accessor :invoices, :adjustments, :refunds

    def page = :invoices

    def invoice_total(invoice)
      display_amount(invoice.total_minor, invoice.currency_code)
    end

    def invoice_status(invoice)
      money_state(invoice.state)
    end

    def adjustment_label(adjustment)
      "#{money_state(adjustment.kind)}: #{display_amount(adjustment.amount_minor, adjustment.currency_code)}"
    end

    def refund_label(refund)
      "#{copy('refund_title', 'Refund')}: #{display_amount(refund.amount_minor, refund.currency_code)}"
    end
  end
end
