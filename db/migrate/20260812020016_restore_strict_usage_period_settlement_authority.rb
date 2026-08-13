# frozen_string_literal: true

class RestoreStrictUsagePeriodSettlementAuthority < ActiveRecord::Migration[8.1]
  def up
    execute "DROP TRIGGER rs_billing_rated_usage_settlement_history ON recording_studio_billing_rated_usage_settlements"
    execute "DROP FUNCTION rs_billing_protect_rated_usage_settlement()"
    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_rated_usage_settlement() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'rated usage settlements are append-only'; END IF;
        IF NEW.usage_period_id IS NULL OR NEW.rated_usage_id IS NOT NULL OR NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_usage_periods period
          JOIN recording_studio_billing_financial_commands command ON command.id = NEW.financial_command_id
          JOIN recording_studio_billing_commercial_manifests manifest ON manifest.manifest_digest = NEW.manifest_digest
          WHERE period.id = NEW.usage_period_id AND period.state = 'closed'
            AND period.root_recording_id = NEW.root_recording_id AND period.account_recording_id = NEW.account_recording_id
            AND command.command_type = 'usage_settlement' AND command.root_recording_id = NEW.root_recording_id
            AND command.account_recording_id = NEW.account_recording_id AND command.provider_account_recording_id = NEW.provider_account_recording_id
            AND command.canonical_request -> 'request' = NEW.canonical_request
            AND command.request_fingerprint = NEW.request_fingerprint
            AND NEW.canonical_request ->> 'usage_period_id' = period.id::text
            AND manifest.used_at IS NOT NULL
        ) THEN RAISE EXCEPTION 'usage period settlement source authority is invalid'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_rated_usage_settlement_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_rated_usage_settlements
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_rated_usage_settlement();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
