# frozen_string_literal: true

module RecordingStudioBilling
  class InvoicePresenter < BasePresenter
    attr_accessor :invoice, :adjustments, :refunds, :payments

    def page = :invoice

    def invoice_heading
      invoice_label(invoice)
    end

    def invoice_total
      display_amount(invoice.total_minor, invoice.currency_code)
    end

    def invoice_status
      money_state(invoice.state)
    end

    def line_rows
      invoice.lines.map do |line|
        {
          description: line.description.presence || copy("invoice_item", "Invoice item"),
          quantity: line.quantity,
          amount: display_amount(line.amount_minor, line.currency_code)
        }
      end
    end

    def financial_rows
      Array(payments).map do |payment|
        "#{copy('payments_title', 'Payments')} #{display_amount(payment.amount_minor, payment.currency_code)}: #{money_state(payment.financial_command&.state || payment.state)}"
      end +
        Array(refunds).map do |refund|
          "#{copy('refund_title', 'Refund')} #{display_amount(refund.amount_minor, refund.currency_code)}: #{money_state(refund.financial_command.state)}"
        end +
        Array(adjustments).map do |adjustment|
          "#{money_state(adjustment.kind)} #{display_amount(adjustment.amount_minor, adjustment.currency_code)}: #{money_state(adjustment.financial_command.state)}"
        end
    end
  end
end
