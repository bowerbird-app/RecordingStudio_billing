# frozen_string_literal: true

module RecordingStudioBilling
  class BillingNavigationComponent < BaseComponent
    def initialize(presenter:, current_page:)
      super()
      @presenter = presenter
      @current_page = current_page.to_sym
    end

    def items
      default_items + @presenter.navigation_items
    end

    private

    def default_items
      root_id = @presenter.root_recording.id
      [
        { page: :overview, label: "Overview", href: helpers.billing_path(root_recording_id: root_id), icon: :home },
        { page: :subscriptions, label: "Plan", href: helpers.plan_billing_path(root_recording_id: root_id),
          icon: :credit_card },
        { page: :addons, label: "Add-ons", href: helpers.addons_billing_path(root_recording_id: root_id), icon: :plus },
        { page: :usage, label: "Usage", href: helpers.usage_billing_path(root_recording_id: root_id),
          icon: :chart_bar },
        { page: :invoices, label: "Invoices", href: helpers.invoices_billing_path(root_recording_id: root_id),
          icon: :document },
        { page: :payments, label: "Payments", href: helpers.payments_billing_path(root_recording_id: root_id),
          icon: :credit_card },
        { page: :settings, label: "Billing settings", href: helpers.settings_billing_path(root_recording_id: root_id),
          icon: :settings }
      ]
    end
  end
end
