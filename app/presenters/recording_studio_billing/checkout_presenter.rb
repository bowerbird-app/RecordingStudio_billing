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
  end
end
