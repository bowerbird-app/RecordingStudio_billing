# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end

    private

    attr_reader :presenter

    def checkout_status_copy
      presenter.respond_to?(:status_copy) ? presenter.status_copy : presenter.checkout_intent.state.to_s.humanize
    end

    def checkout_line_rows
      if presenter.respond_to?(:frozen_line_rows)
        presenter.frozen_line_rows
      else
        Array(presenter.frozen_lines).map { |line| fallback_line_row(line) }
      end
    end

    def fallback_line_row(line)
      price = line.fetch("price", {})
      option = line.fetch("billing_option", {})
      {
        label: line.dig("product", "name").presence || "Plan",
        amount: [price["amount_minor"], price["currency_code"]].compact.join(" "),
        quantity: price["quantity"] || 1,
        cadence: option["recurrence"] == "recurring" ? option["interval"] : "one-time",
        tax: "Tax is calculated at checkout"
      }
    end

    def render_checkout_action
      action = presenter.checkout_action if presenter.respond_to?(:checkout_action)
      if action
        render_action(action)
      elsif presenter.respond_to?(:embedded?) && presenter.embedded?
        helpers.tag.p(presenter.copy("checkout_pending", "Your payment is being prepared or is awaiting provider confirmation."))
      elsif presenter.respond_to?(:redirect?) && presenter.redirect?
        render FlatPack::Button::Component.new(
          text: presenter.copy("checkout_continue", "Continue to secure checkout"),
          style: :primary, size: :md, url: presenter.presentation[:url], data: { turbo: false }
        )
      else
        helpers.tag.p(presenter.copy("checkout_pending", "Your payment is being prepared or is awaiting provider confirmation."))
      end
    end

    def render_action(action)
      if action[:kind] == :button && action[:url].present?
        render FlatPack::Button::Component.new(
          text: action[:text], style: :primary, size: :md, url: action[:url], data: { turbo: false }
        )
      else
        helpers.tag.p(action[:text], data: { checkout_action: presenter.respond_to?(:presentation_mode) ? presenter.presentation_mode : nil })
      end
    end
  end
end
