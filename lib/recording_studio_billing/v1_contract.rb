# frozen_string_literal: true

module RecordingStudioBilling
  # Canonical V1 vocabulary shared by models, PostgreSQL checks, and adapters.
  module V1Contract
    PRICE_SCOPE = "market"
    CHECKOUT_MODES = %w[embedded redirect payment_link invoice no_charge].freeze
    COLLECTION_METHODS = %w[automatic send_invoice].freeze
    TAX_POLICIES = %w[inclusive exclusive provider_default].freeze

    PROVIDER_OPERATIONS = %w[checkout subscription_change refund adjustment].freeze
    PROVIDER_CURRENCIES = %w[usd eur gbp].freeze
    PROVIDER_QUANTITIES = %w[fixed adjustable].freeze
    PROVIDER_COMPOSITION = %w[single mixed].freeze
    PROVIDER_REFUNDS = %w[full partial].freeze
    PROVIDER_ADJUSTMENTS = %w[credit debit].freeze
    PROVIDER_SUBSCRIPTION_CHANGE_KINDS = %w[cancellation resumption plan interval addon quantity].freeze

    def self.provider_capabilities(**overrides)
      ProviderCapabilities.new(
        operations: PROVIDER_OPERATIONS,
        currencies: PROVIDER_CURRENCIES,
        collection_methods: COLLECTION_METHODS,
        checkout_modes: CHECKOUT_MODES,
        tax_modes: %w[provider],
        quantities: PROVIDER_QUANTITIES,
        composition: PROVIDER_COMPOSITION,
        refunds: PROVIDER_REFUNDS,
        adjustments: PROVIDER_ADJUSTMENTS,
        subscription_change_kinds: PROVIDER_SUBSCRIPTION_CHANGE_KINDS,
        **overrides
      )
    end
  end
end
