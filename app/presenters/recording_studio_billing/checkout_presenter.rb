# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutPresenter < BasePresenter
    STATUS_COPY = {
      "draft" => ["checkout_status_draft", "Checkout is being prepared."],
      "validated" => ["checkout_status_validated", "Checkout is ready to continue."],
      "pending_provider" => ["checkout_status_pending", "Checkout is being prepared."],
      "awaiting_confirmation" => ["checkout_status_awaiting", "Waiting for payment confirmation."],
      "requires_requote" => ["checkout_status_requote", "The price changed. Start checkout again to see the current price."],
      "requires_restart" => ["checkout_status_restart", "Checkout needs to start again with the current price and terms."],
      "requires_review" => ["checkout_status_review", "This purchase needs a review before it can continue."],
      "rejected" => ["checkout_status_rejected", "This purchase is not available for your location."],
      "completed" => ["checkout_status_completed", "Purchase complete."],
      "failed" => ["checkout_status_failed", "Checkout could not be completed."],
      "cancelled" => ["checkout_status_cancelled", "Checkout was cancelled."],
      "expired" => ["checkout_status_expired", "Checkout expired. Start again to continue."]
    }.freeze

    ACTION_COPY = {
      "embedded" => ["checkout_pending", "Your payment is being prepared or is awaiting provider confirmation."],
      "redirect" => ["checkout_continue", "Continue to secure checkout"],
      "payment_link" => ["checkout_payment_link", "Open payment link"],
      "invoice" => ["checkout_invoice", "Continue to invoice"],
      "no_charge" => ["checkout_no_charge", "No payment is due for this plan."]
    }.freeze

    attr_accessor :checkout_intent, :presentation

    def page = :checkout

    def presentation_mode
      item = checkout_intent.items.first
      item_presentation = item.respond_to?(:presentation) ? item.presentation : nil
      (presentation_value(:mode).presence || item_presentation).to_s
    end

    def presentation_url
      presentation_value(:url)
    end

    def embedded? = presentation_mode == "embedded"
    def redirect? = presentation_mode == "redirect"
    def payment_link? = presentation_mode == "payment_link"
    def invoice? = presentation_mode == "invoice"
    def no_charge? = presentation_mode == "no_charge"

    def status_copy
      key, default = STATUS_COPY.fetch(checkout_intent.state) { ["checkout_status_pending", checkout_intent.state.to_s.humanize] }
      copy(key, default)
    end

    def checkout_action
      return { kind: :notice, text: copy("checkout_no_charge", "No payment is due for this plan.") } if checkout_intent.state == "completed" && no_charge?

      return if blocked_checkout?

      key, default = ACTION_COPY.fetch(presentation_mode) { ACTION_COPY.fetch("embedded") }
      text = copy(key, default)
      if %w[redirect payment_link invoice].include?(presentation_mode)
        return { kind: :button, text:, url: presentation_url } if presentation_url.present?

        { kind: :notice, text: copy("checkout_pending", "Your payment is being prepared or is awaiting provider confirmation.") }
      else
        { kind: :notice, text: }
      end
    end

    def frozen_lines
      checkout_intent.items.map do |item|
        item.commercial_manifest.fetch("canonical_data", {}).slice("product", "billing_option", "price", "tax",
                                                                   "benefits", "overage")
      end
    end

    def frozen_line_rows
      checkout_intent.items.map do |item|
        line = item.commercial_manifest.fetch("canonical_data", {})
        price = line.fetch("price", {})
        option = line.fetch("billing_option", {})
        {
          label: snapshot_value(line, "product", "name").presence || "Plan",
          amount: display_amount(price["amount_minor"], price["currency_code"]),
          quantity: item.quantity,
          cadence: cadence_label(option),
          tax: tax_at_checkout_copy(line["tax"])
        }
      end
    end

    private

    def presentation_value(key)
      values = presentation.respond_to?(:to_h) ? presentation.to_h : {}
      values[key] || values[key.to_s]
    end

    def blocked_checkout?
      %w[requires_requote requires_restart requires_review rejected failed cancelled expired completed].include?(
        checkout_intent.state
      )
    end

    def cadence_label(option)
      return copy("checkout_cadence_one_time", "one-time") unless option["recurrence"] == "recurring"

      case option["interval"]
      when "year" then copy("checkout_cadence_yearly", "yearly")
      when "week" then copy("checkout_cadence_weekly", "weekly")
      else copy("checkout_cadence_monthly", "monthly")
      end
    end

    def tax_at_checkout_copy(tax)
      return copy("checkout_tax_at_checkout", "Tax is calculated at checkout") unless tax.is_a?(Hash)

      amount = tax["amount_minor"] || tax[:amount_minor]
      currency = tax["currency_code"] || tax[:currency_code]
      return display_amount(amount, currency) if amount.present?

      copy("checkout_tax_at_checkout", "Tax is calculated at checkout")
    end
  end
end
