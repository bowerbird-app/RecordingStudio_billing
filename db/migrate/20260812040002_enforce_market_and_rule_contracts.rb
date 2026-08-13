# frozen_string_literal: true

class EnforceMarketAndRuleContracts < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION rs_billing_country_code_array_valid(value jsonb) RETURNS boolean AS $$
        SELECT jsonb_typeof(value) = 'array'
          AND NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements_text(value) AS code
            WHERE code !~ '^[A-Z]{2}$'
          );
      $$ LANGUAGE sql IMMUTABLE;
    SQL
    add_check_constraint :recording_studio_billing_markets,
                         "rs_billing_country_code_array_valid(regional_country_codes)",
                         name: "rs_billing_markets_regional_country_codes"
    add_check_constraint :recording_studio_billing_markets,
                         "NOT global_fallback OR (country_codes = '[]'::jsonb AND country_groups = '{}'::jsonb AND regional_country_codes = '[]'::jsonb)",
                         name: "rs_billing_markets_global_fallback_scope"
    change_column_null :recording_studio_billing_product_rules, :target_product_recording_id, false
  end

  def down
    change_column_null :recording_studio_billing_product_rules, :target_product_recording_id, true
    remove_check_constraint :recording_studio_billing_markets, name: "rs_billing_markets_global_fallback_scope"
    remove_check_constraint :recording_studio_billing_markets, name: "rs_billing_markets_regional_country_codes"
    execute "DROP FUNCTION rs_billing_country_code_array_valid(jsonb)"
  end
end
