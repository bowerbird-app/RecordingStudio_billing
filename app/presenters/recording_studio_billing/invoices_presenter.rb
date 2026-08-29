# frozen_string_literal: true

module RecordingStudioBilling
  class InvoicesPresenter < BasePresenter
    attr_accessor :invoices, :adjustments, :refunds, :refund_intents, :adjustment_intents

    def page = :invoices

    def invoice_total(invoice)
      display_amount(invoice.total_minor, invoice.currency_code)
    end

    def invoice_status(invoice)
      money_state(invoice.state)
    end

    def adjustment_label(adjustment)
      "#{money_state(adjustment.kind)} · #{display_amount(adjustment.amount_minor, adjustment.currency_code)}"
    end

    def refund_label(refund)
      "#{copy('refund_title', 'Refund')} · #{display_amount(refund.amount_minor, refund.currency_code)}"
    end

    def pending_money_rows
      Array(refund_intents).reject { |intent| intent.try(:refund) }.map do |intent|
        status = money_state(intent.financial_command&.state || intent.state)
        "#{copy('refund_title', 'Refund')} · #{display_amount(intent.amount_minor, intent.currency_code)} (#{status})"
      end + Array(adjustment_intents).reject { |intent| intent.try(:financial_adjustment) }.map do |intent|
        status = money_state(intent.financial_command&.state || intent.state)
        "#{money_state(intent.kind)} · #{display_amount(intent.amount_minor, intent.currency_code)} (#{status})"
      end
    end
  end
end
