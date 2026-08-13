# frozen_string_literal: true

class ReplaceDirectUsageSettlementAuthority < ActiveRecord::Migration[8.1]
  def up
    execute "DROP TRIGGER rs_billing_rated_usage_history ON recording_studio_billing_rated_usages"
    execute "DROP FUNCTION rs_billing_protect_rated_usage()"
    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_rated_usage() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'rated usages are append-only'; END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_meter_aggregations aggregation
          JOIN recording_studio_billing_commercial_manifests manifest ON manifest.manifest_digest = NEW.manifest_digest
          WHERE aggregation.id = NEW.meter_aggregation_id AND aggregation.root_recording_id = NEW.root_recording_id
            AND aggregation.account_recording_id = NEW.account_recording_id AND aggregation.manifest_digest = NEW.manifest_digest
            AND aggregation.window_starts_at = NEW.window_starts_at AND aggregation.window_ends_at = NEW.window_ends_at
            AND manifest.used_at IS NOT NULL AND NEW.aggregation_snapshot = aggregation.input_snapshot
            AND NEW.rate_snapshot -> 'rate' = manifest.canonical_data #> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text]
            AND NEW.rate_snapshot -> 'customer_rate' = manifest.canonical_data #> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text]
            AND NEW.quantity = aggregation.quantity * (manifest.canonical_data #>> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'conversion_numerator'])::bigint / (manifest.canonical_data #>> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'conversion_denominator'])::bigint
        ) OR NEW.customer_amount_minor IS NOT NULL OR NEW.customer_currency_code IS NOT NULL OR NEW.customer_currency_exponent IS NOT NULL THEN
          RAISE EXCEPTION 'rated usage source authority is invalid';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_rated_usage_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_rated_usages FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_rated_usage();
    SQL

    execute "DROP TRIGGER rs_billing_rated_usage_settlement_history ON recording_studio_billing_rated_usage_settlements"
    execute "DROP FUNCTION rs_billing_protect_rated_usage_settlement()"
    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_rated_usage_settlement() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'rated usage settlements are append-only'; END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_usage_allocations allocation
          JOIN recording_studio_billing_overage_calculations overage ON overage.usage_allocation_id = allocation.id
          JOIN recording_studio_billing_rated_usages rated ON rated.id = allocation.rated_usage_id
          JOIN recording_studio_billing_financial_commands command ON command.id = NEW.financial_command_id
          WHERE allocation.rated_usage_id = NEW.rated_usage_id AND allocation.root_recording_id = NEW.root_recording_id
            AND allocation.account_recording_id = NEW.account_recording_id AND allocation.state = 'closed'
            AND rated.manifest_digest = NEW.manifest_digest AND command.command_type = 'usage_settlement'
            AND command.root_recording_id = NEW.root_recording_id AND command.account_recording_id = NEW.account_recording_id
            AND command.provider_account_recording_id = NEW.provider_account_recording_id
            AND command.canonical_request -> 'request' = NEW.canonical_request AND command.request_fingerprint = NEW.request_fingerprint
            AND NEW.canonical_request ->> 'rated_usage_id' = rated.id::text
            AND NEW.canonical_request ->> 'usage_allocation_id' = allocation.id::text
            AND NEW.canonical_request ->> 'amount_minor' = overage.amount_minor::text
            AND NEW.canonical_request ->> 'currency' = overage.currency_code
        ) THEN RAISE EXCEPTION 'rated usage settlement source authority is invalid'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_rated_usage_settlement_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_rated_usage_settlements FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_rated_usage_settlement();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
