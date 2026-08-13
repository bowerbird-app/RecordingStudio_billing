# frozen_string_literal: true

class AddExplicitMarketFallbacks < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_studio_billing_markets, :regional_country_codes, :jsonb, null: false, default: []
    add_column :recording_studio_billing_markets, :global_fallback, :boolean, null: false, default: false

    execute <<~SQL.squish
      UPDATE recording_studio_billing_markets
      SET global_fallback = true,
          country_codes = '[]'::jsonb,
          country_groups = '{}'::jsonb,
          regional_country_codes = '[]'::jsonb
      WHERE fallback = true
    SQL
    remove_column :recording_studio_billing_markets, :fallback
  end

  def down
    add_column :recording_studio_billing_markets, :fallback, :boolean, null: false, default: false
    execute "UPDATE recording_studio_billing_markets SET fallback = global_fallback"
    remove_column :recording_studio_billing_markets, :global_fallback
    remove_column :recording_studio_billing_markets, :regional_country_codes
  end
end
