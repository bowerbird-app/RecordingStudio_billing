# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutPresenter < BasePresenter
    attr_accessor :checkout_intent, :presentation

    def page = :checkout

    def embedded? = presentation[:mode] == "embedded"

    def redirect? = presentation[:mode] == "redirect"

    def frozen_lines
      checkout_intent.items.map do |item|
        item.commercial_manifest.fetch("canonical_data", {}).slice("product", "billing_option", "price", "tax",
                                                                   "benefits", "overage")
      end
    end

    def frozen_line_rows
      checkout_intent.items.map do |item|
        line = item.commercial_manifest.fetch("canonical_data", {}).slice("product", "billing_option", "price", "tax",
                                                                          "benefits", "overage", "market")
        price = line.fetch("price", {})
        option = line.fetch("billing_option", {})
        {
          label: snapshot_value(line, "product", "name") || snapshot_value(line, "product", "key") || "Billing item",
          amount: display_amount(price["amount_minor"], price["currency_code"]),
          quantity: item.quantity, recurrence: option["recurrence"], interval: option["interval"],
          tax: display_value(line["tax"]), benefits: display_value(line["benefits"]),
          overage: display_value(line["overage"]), market: display_value(line["market"])
        }
      end
    end
  end
end
