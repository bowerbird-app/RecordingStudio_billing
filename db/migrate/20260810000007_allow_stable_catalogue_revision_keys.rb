# frozen_string_literal: true

class AllowStableCatalogueRevisionKeys < ActiveRecord::Migration[8.1]
  TABLES = CorrectV1BillingContract::COMMERCIAL_TABLES.freeze

  def up
    TABLES.each { |table| remove_index table, name: "#{table}_key" if index_exists?(table, :key, name: "#{table}_key") }
    remove_index :recording_studio_billing_prices, name: "recording_studio_billing_prices_historical_version"
    remove_index :recording_studio_billing_overage_prices,
                 name: "recording_studio_billing_overage_prices_historical_version"
  end

  def down
    add_index :recording_studio_billing_prices,
              %i[billing_option_recording_id scope market_recording_id currency_code version],
              unique: true, name: "recording_studio_billing_prices_historical_version"
    add_index :recording_studio_billing_overage_prices,
              %i[billing_option_recording_id scope market_recording_id usage_unit_recording_id currency_code version],
              unique: true, name: "recording_studio_billing_overage_prices_historical_version"
    TABLES.each { |table| add_index table, :key, unique: true, name: "#{table}_key" }
  end
end
