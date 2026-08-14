# frozen_string_literal: true

class ProtectOverageCalculationHistory < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_overage_calculation() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN
          RAISE EXCEPTION 'overage calculations are append-only';
        END IF;

        IF NOT EXISTS (
          SELECT 1
          FROM recording_studio_billing_usage_allocations allocation
          JOIN recording_studio_billing_rated_usages rated ON rated.id = allocation.rated_usage_id
          JOIN recording_studio_billing_commercial_manifests manifest ON manifest.manifest_digest = rated.manifest_digest
          WHERE allocation.id = NEW.usage_allocation_id
            AND manifest.used_at IS NOT NULL
            AND NEW.excess_quantity = allocation.excess_quantity
            AND NEW.rate_snapshot ->> 'manifest_digest' = rated.manifest_digest
            AND NEW.rate_snapshot ->> 'usage_unit_recording_id' = rated.rate_snapshot #>> '{meter,usage_unit_recording_id}'
            AND NEW.rate_snapshot ->> 'currency_code' = NEW.currency_code
            AND (NEW.rate_snapshot ->> 'currency_exponent')::integer = NEW.currency_exponent
        ) THEN
          RAISE EXCEPTION 'overage calculation source authority is invalid';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER rs_billing_overage_calculation_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_overage_calculations
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_overage_calculation();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS rs_billing_overage_calculation_history ON recording_studio_billing_overage_calculations"
    execute "DROP FUNCTION IF EXISTS rs_billing_protect_overage_calculation()"
  end
end
