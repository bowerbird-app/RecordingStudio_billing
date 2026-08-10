# frozen_string_literal: true

class AllowStableCatalogueRevisionKeys < ActiveRecord::Migration[8.1]
  TABLES = %i[
    recording_studio_billing_provider_accounts recording_studio_billing_markets
    recording_studio_billing_products recording_studio_billing_billing_options
    recording_studio_billing_prices recording_studio_billing_overage_prices
    recording_studio_billing_features recording_studio_billing_feature_overrides
    recording_studio_billing_product_rules recording_studio_billing_plan_updates
    recording_studio_billing_usage_units recording_studio_billing_meters
    recording_studio_billing_rate_cards recording_studio_billing_rates
    recording_studio_billing_cost_cards recording_studio_billing_cost_rates
  ].freeze

  def up
    TABLES.each { |table| remove_index table, name: "#{table}_key" if index_exists?(table, :key, name: "#{table}_key") }
    remove_index :recording_studio_billing_prices, name: "recording_studio_billing_prices_historical_version",
                                                    if_exists: true
    remove_index :recording_studio_billing_overage_prices,
                 name: "recording_studio_billing_overage_prices_historical_version", if_exists: true
  end

  def down
    add_index :recording_studio_billing_prices,
              %i[billing_option_recording_id scope market_recording_id currency_code version],
              unique: true, name: "recording_studio_billing_prices_historical_version"
    add_index :recording_studio_billing_overage_prices,
              %i[billing_option_recording_id scope market_recording_id usage_unit_recording_id currency_code version],
              unique: true, name: "recording_studio_billing_overage_prices_historical_version"
  end
end
