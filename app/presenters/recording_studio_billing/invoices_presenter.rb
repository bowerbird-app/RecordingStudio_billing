# frozen_string_literal: true

module RecordingStudioBilling
  class InvoicesPresenter < BasePresenter
    attr_accessor :invoices, :adjustments, :refunds

    def page = :invoices

    def invoice_total(invoice)
      display_amount(invoice.total_minor, invoice.currency_code)
    end

    def invoice_status(invoice)
      [invoice.state.humanize, invoice.financial_command&.state&.humanize].compact.join(" | ")
    end
  end
end
