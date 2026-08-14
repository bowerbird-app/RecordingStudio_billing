# frozen_string_literal: true

module RecordingStudioBilling
  module AccessActions
    # Canonical engine actions and their minimum RecordingStudioAccessible roles.
    # Customer controllers authorize only these actions; usage ingestion remains
    # a trusted server integration and is intentionally absent from this catalog.
    CUSTOMER = {
      view_billing: :view,
      start_checkout: :edit,
      view_checkout: :view,
      request_subscription_change: :edit,
      cancel_subscription: :edit,
      resume_subscription: :edit,
      view_payments: :view,
      view_refunds: :view,
      view_adjustments: :view,
      view_invoices: :view,
      download_invoice: :view,
      edit_billing_settings: :edit
    }.freeze

    SITE = {
      commercial_operations: :admin,
      financial_operations: :admin,
      reconciliation: :admin,
      recovery: :admin
    }.freeze

    ALL = CUSTOMER.merge(SITE).freeze

    def self.role_for(action)
      ALL.fetch(action.to_sym)
    end

    def self.customer_action?(action)
      CUSTOMER.key?(action.to_sym)
    end
  end
end
