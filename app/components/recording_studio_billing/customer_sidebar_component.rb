# frozen_string_literal: true

module RecordingStudioBilling
  class CustomerSidebarComponent < BaseComponent
    def initialize(root_recording_id: nil, current_page: nil)
      super()
      @root_recording_id = root_recording_id
      @current_page = current_page&.to_sym
    end

    def items
      default_items + extra_items
    end

    def current_page
      @current_page || inferred_page
    end

    def billing_open?
      current_page.present? || helpers.request&.path.to_s.include?("/billing")
    end

    private

    def default_items
      [
        { page: :overview, label: "Overview", href: overview_href, icon: :home },
        { page: :subscriptions, label: "Plan", href: billing_path(:plan_billing_path), icon: :credit_card },
        { page: :plan_requests, label: "Plan requests", href: billing_path(:plan_requests_billing_path),
          icon: :document },
        { page: :addons, label: "Add-ons", href: billing_path(:addons_billing_path), icon: :plus },
        { page: :usage, label: "Usage", href: billing_path(:usage_billing_path), icon: :chart_bar },
        { page: :invoices, label: "Invoices", href: billing_path(:invoices_billing_path), icon: :document },
        { page: :payments, label: "Payments", href: billing_path(:payments_billing_path), icon: :credit_card },
        { page: :settings, label: "Billing settings", href: billing_path(:settings_billing_path), icon: :settings }
      ]
    end

    def extra_items
      presenter = BasePresenter.new(root_recording: Struct.new(:id).new(@root_recording_id))
      Array(RecordingStudioBilling.configuration.hooks.billing_navigation_items(presenter)).filter_map do |item|
        next if item[:href].blank? || item[:label].blank?

        item.merge(page: item[:page] || item[:label].to_s.parameterize.underscore.to_sym)
      end
    end

    def inferred_page
      path = helpers.request&.path.to_s
      return :plan_requests if path.include?("plan_requests")
      return :subscriptions if path.include?("/plan")
      return :addons if path.include?("/addons")
      return :usage if path.include?("/usage")
      return :invoices if path.include?("/invoices")
      return :payments if path.include?("/payments")
      return :settings if path.include?("/settings")
      return :overview if path.match?(%r{/billing(/billing)?/?$})

      nil
    end

    def overview_href
      path = billing_routes.root_path
      return path if @root_recording_id.blank?

      separator = path.include?("?") ? "&" : "?"
      "#{path}#{separator}root_recording_id=#{ERB::Util.url_encode(@root_recording_id.to_s)}"
    end

    def billing_path(helper_name)
      args = @root_recording_id.present? ? [{ root_recording_id: @root_recording_id }] : []
      billing_routes.public_send(helper_name, *args)
    end

    def billing_routes
      if helpers.respond_to?(:plan_billing_path)
        helpers
      elsif helpers.respond_to?(:recording_studio_billing)
        helpers.recording_studio_billing
      else
        Engine.routes.url_helpers
      end
    end
  end
end
