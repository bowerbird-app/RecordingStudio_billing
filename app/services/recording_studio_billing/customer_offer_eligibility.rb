# frozen_string_literal: true

module RecordingStudioBilling
  class CustomerOfferEligibility
    def self.call(...) = new(...).call

    def initialize(root_recording:, account_recording:, kinds:, location_context: nil)
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @account_recording = account_recording
      @kinds = Array(kinds)
      @location_context = location_context || default_location_context
    end

    def call
      published_options.select { |option| eligible?(option) }
    end

    private

    attr_reader :account_recording, :kinds, :location_context, :root_recording

    def published_options
      BillingOption.with_current_recording.where(state: "published").order(:created_at).select do |option|
        product = option.product_recording&.recordable
        product.is_a?(Product) && product.state == "published" && kinds.include?(product.kind) && option.checkout_policy == "allowed"
      end
    end

    def eligible?(option)
      product = option.product_recording.recordable
      resolution = DisplayMarketResolver.call(product:, root_recording:, account_recording:, location_context:)
      price = CommercialPriceSelector.new(billing_option: option, market: resolution.market,
                                          currency_code: resolution.currency_code).price!
      presentation = checkout_presentation(option, product, price, resolution)
      return false unless product_rules_allow?(product)

      CommercialManifestResolver.new(
        product:, billing_option: option, price:, market: resolution.market, currency_code: resolution.currency_code,
        account_recording:, trusted_context: { country_code: resolution.country_code, market_recording_id: resolution.market.recording.id,
                                               currency_code: resolution.currency_code, quantity: option.default_quantity }
      ).resolve!
      presentation.present?
    rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, ArgumentError
      false
    end

    def checkout_presentation(option, product, price, resolution)
      adapter = RecordingStudioBilling.provider_adapter(product.provider_account_recording.recordable.adapter_key)
      presentation = if option.collection_method == "invoice"
                       "invoice"
                     else
                       (if price.amount_minor.zero?
                          "no_charge"
                        else
                          adapter.capabilities.evaluate(checkout_modes: "embedded").supported? ? "embedded" : "redirect"
                        end)
                     end
      capability = adapter.capabilities.evaluate(
        operations: "checkout", currencies: resolution.currency_code, markets: resolution.country_code,
        collection_methods: option.collection_method, checkout_modes: presentation, quantities: option.quantity_mode,
        composition: "single"
      )
      capability.supported? ? presentation : nil
    end

    def product_rules_allow?(product)
      selected = active_subscription_products + [product]
      ProductRuleEvaluator.new(product:, selected_products: selected,
                               current_product: active_plan_product).evaluate.eligible
    end

    def active_subscription_products
      Subscription.for_root(root_recording).where(account_recording:,
                                                  state: %w[trialing
                                                            active]).flat_map do |subscription|
        subscription.item_versions.where(effective_ends_at: nil).filter_map do |version|
          version.product_recording&.recordable
        end
      end
    end

    def active_plan_product
      active_subscription_products.find { |product| product.kind == "plan" }
    end

    def default_location_context
      account = account_recording.recordable
      host_context = RecordingStudioBilling.configuration.billing_location_context_resolver&.call(
        root_recording:, account_recording:
      ).to_h || {}
      host_context.symbolize_keys.merge(
        declaration_country: account.billing_country_code,
        account_currency: account.billing_currency_code
      )
    rescue NoMethodError
      {}
    end
  end
end
