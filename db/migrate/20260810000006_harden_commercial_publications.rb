# frozen_string_literal: true

class HardenCommercialPublications < ActiveRecord::Migration[8.1]
  def up
    CorrectV1BillingContract::COMMERCIAL_TABLES.each do |table|
      remove_index table, name: "#{table}_key" if index_exists?(table, :key, name: "#{table}_key")
    end
    remove_index :recording_studio_billing_prices, name: "recording_studio_billing_prices_historical_version"
    remove_index :recording_studio_billing_overage_prices,
                 name: "recording_studio_billing_overage_prices_historical_version"
    add_column :recording_studio_billing_commercial_publication_candidates, :snapshot_envelope, :jsonb,
               null: false, default: {}
    add_index :recording_studio_billing_commercial_publication_candidates,
              %i[root_recording_id effective_at], unique: true,
              name: "rs_billing_publication_candidate_identity"
    add_check_constraint :recording_studio_billing_rates,
                         "NOT (conversion_numerator IS NULL AND conversion_denominator IS NULL AND conversion_decimal IS NULL)",
                         name: "rs_billing_rates_conversion_present"
  end

  def down
    remove_check_constraint :recording_studio_billing_rates, name: "rs_billing_rates_conversion_present"
    remove_index :recording_studio_billing_commercial_publication_candidates,
                 name: "rs_billing_publication_candidate_identity"
    remove_column :recording_studio_billing_commercial_publication_candidates, :snapshot_envelope
    CorrectV1BillingContract::COMMERCIAL_TABLES.each do |table|
      add_index table, :key, unique: true, name: "#{table}_key"
    end
    add_index :recording_studio_billing_prices,
              %i[billing_option_recording_id scope market_recording_id currency_code version],
              unique: true, name: "recording_studio_billing_prices_historical_version"
    add_index :recording_studio_billing_overage_prices,
              %i[billing_option_recording_id scope market_recording_id usage_unit_recording_id currency_code version],
              unique: true, name: "recording_studio_billing_overage_prices_historical_version"
  end
end
