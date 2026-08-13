# frozen_string_literal: true

module RecordingStudioBilling
  class InvoicesController < ApplicationController
    before_action :load_invoice
    before_action -> { authorize_billing_action!(action_name == "download" ? :download_invoice : :view_invoices) }

    def show
      presenter_class = RecordingStudioBilling.configuration.billing_presenter_for(
        :invoice, RecordingStudioBilling::InvoicePresenter
      )
      @presenter = presenter_class.new(root_recording:, invoice: @invoice)
    end

    def download
      command = @invoice.financial_command
      adapter = command && RecordingStudioBilling.provider_adapter(command.provider_adapter_key)
      raise ActiveRecord::RecordNotFound unless adapter.respond_to?(:invoice_download)

      response.headers["Cache-Control"] = "private, no-store"
      download = adapter.invoice_download(invoice: @invoice, provider_reference: command.provider_reference)
      raise ActiveRecord::RecordNotFound unless download.is_a?(StripeAdapter::TrustedInvoiceDownload)

      response.content_type = "application/pdf"
      response.headers["Content-Disposition"] = %(attachment; filename="invoice-#{@invoice.id}.pdf")
      self.response_body = download.each
    end

    private

    def load_invoice
      @invoice = Invoice.where(root_recording:, account_recording:).find(params[:id])
    end
  end
end
