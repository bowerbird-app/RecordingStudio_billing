# frozen_string_literal: true

class BindOverageCalculationsToPublishedPrices < ActiveRecord::Migration[8.1]
  LIMIT_COLUMNS = %i[
    review_threshold_minor hard_threshold_minor maximum_period_liability_minor maximum_submission_minor
  ].freeze

  def up
    LIMIT_COLUMNS.each { |column| add_column :recording_studio_billing_overage_prices, column, :bigint }
    add_check_constraint :recording_studio_billing_overage_prices,
                         "review_threshold_minor IS NULL OR review_threshold_minor >= 0",
                         name: "rs_billing_overage_review_threshold"
    add_check_constraint :recording_studio_billing_overage_prices,
                         "hard_threshold_minor IS NULL OR hard_threshold_minor >= 0",
                         name: "rs_billing_overage_hard_threshold"
    add_check_constraint :recording_studio_billing_overage_prices,
                         "maximum_period_liability_minor IS NULL OR maximum_period_liability_minor >= 0",
                         name: "rs_billing_overage_period_liability_limit"
    add_check_constraint :recording_studio_billing_overage_prices,
                         "maximum_submission_minor IS NULL OR maximum_submission_minor >= 0",
                         name: "rs_billing_overage_submission_limit"

    add_reference :recording_studio_billing_overage_calculations, :overage_price_recording,
                  type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
    execute <<~SQL
      DROP TRIGGER rs_billing_overage_calculation_history ON recording_studio_billing_overage_calculations;
      DROP FUNCTION rs_billing_protect_overage_calculation();
      CREATE FUNCTION rs_billing_protect_overage_calculation() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'overage calculations are append-only'; END IF;
        IF NOT EXISTS (
          SELECT 1
          FROM recording_studio_billing_usage_allocations allocation
          JOIN recording_studio_billing_rated_usages rated ON rated.id = allocation.rated_usage_id
          JOIN recording_studio_billing_commercial_manifests manifest ON manifest.manifest_digest = rated.manifest_digest
          CROSS JOIN LATERAL jsonb_array_elements(manifest.canonical_data -> 'overage_prices') price
          WHERE allocation.id = NEW.usage_allocation_id AND allocation.excess_quantity > 0
            AND manifest.used_at IS NOT NULL
            AND NEW.excess_quantity = allocation.excess_quantity
            AND NEW.overage_price_recording_id::text = price ->> 'overage_price_recording_id'
            AND NEW.rate_snapshot ->> 'manifest_digest' = rated.manifest_digest
            AND NEW.rate_snapshot ->> 'overage_price_recording_id' = price ->> 'overage_price_recording_id'
            AND NEW.rate_snapshot ->> 'market_recording_id' = manifest.canonical_data #>> '{usage_settlement,market_recording_id}'
            AND price ->> 'market_recording_id' = manifest.canonical_data #>> '{usage_settlement,market_recording_id}'
            AND NEW.rate_snapshot ->> 'usage_unit_recording_id' = rated.rate_snapshot #>> '{meter,usage_unit_recording_id}'
            AND price ->> 'usage_unit_recording_id' = rated.rate_snapshot #>> '{meter,usage_unit_recording_id}'
            AND NEW.currency_code = price ->> 'currency_code'
            AND NEW.currency_exponent = (price ->> 'currency_exponent')::integer
            AND NEW.rate_snapshot ->> 'currency_code' = price ->> 'currency_code'
            AND (NEW.rate_snapshot ->> 'currency_exponent')::integer = (price ->> 'currency_exponent')::integer
            AND NEW.rate_snapshot ->> 'pricing_model' = price ->> 'pricing_model'
            AND COALESCE((NEW.rate_snapshot ->> 'package_size')::integer, 1) = COALESCE((price ->> 'package_size')::integer, 1)
            AND (NEW.rate_snapshot ->> 'amount_minor')::bigint = (price ->> 'amount_minor')::bigint
            AND NEW.rate_snapshot ->> 'scope' = price ->> 'scope'
            AND (NEW.rate_snapshot ->> 'version')::integer = (price ->> 'version')::integer
            AND NEW.amount_minor = CASE price ->> 'pricing_model'
              WHEN 'flat' THEN (price ->> 'amount_minor')::bigint
              WHEN 'per_unit' THEN allocation.excess_quantity * (price ->> 'amount_minor')::bigint
              WHEN 'package' THEN ((allocation.excess_quantity * (price ->> 'amount_minor')::bigint) + COALESCE((price ->> 'package_size')::integer, 1) - 1) / COALESCE((price ->> 'package_size')::integer, 1)
            END
        ) THEN RAISE EXCEPTION 'overage calculation source authority is invalid'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_overage_calculation_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_overage_calculations
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_overage_calculation();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
