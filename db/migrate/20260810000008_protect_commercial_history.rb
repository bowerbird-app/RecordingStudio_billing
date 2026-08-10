# frozen_string_literal: true

class ProtectCommercialHistory < ActiveRecord::Migration[8.1]
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
  FUNCTION = "rs_billing_protect_commercial_history"

  def up
    execute <<~SQL
      CREATE FUNCTION #{FUNCTION}() RETURNS trigger AS $$
      BEGIN
        IF OLD.state IN ('published', 'retired') THEN
          RAISE EXCEPTION 'published and retired commercial records are immutable';
        END IF;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    TABLES.each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_protect_history
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{FUNCTION}();
      SQL
    end
  end

  def down
    TABLES.each { |table| execute "DROP TRIGGER IF EXISTS #{table}_protect_history ON #{table}" }
    execute "DROP FUNCTION IF EXISTS #{FUNCTION}()"
  end
end
