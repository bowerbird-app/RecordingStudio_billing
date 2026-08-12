# frozen_string_literal: true

class CreateRatedUsageSettlements < ActiveRecord::Migration[8.1]
  def up
    create_table :recording_studio_billing_rated_usage_settlements, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :rated_usage, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_rated_usages }
      t.references :financial_command, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.references :provider_account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.string :manifest_digest, null: false
      t.jsonb :canonical_request, null: false, default: {}
      t.string :request_fingerprint, null: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_rated_usage_settlements, :rated_usage_id, unique: true, name: "idx_rs_billing_settlement_rated_usage"
    add_index :recording_studio_billing_rated_usage_settlements, :financial_command_id, unique: true, name: "idx_rs_billing_settlement_command"
    add_check_constraint :recording_studio_billing_rated_usage_settlements, "manifest_digest ~ '^[0-9a-f]{64}$'", name: "rs_billing_settlement_manifest_digest"
    add_check_constraint :recording_studio_billing_rated_usage_settlements, "request_fingerprint ~ '^[0-9a-f]{64}$'", name: "rs_billing_settlement_fingerprint"
    add_check_constraint :recording_studio_billing_rated_usage_settlements, "jsonb_typeof(canonical_request) = 'object'", name: "rs_billing_settlement_request_object"
    add_check_constraint :recording_studio_billing_rated_usage_settlements, "jsonb_typeof(safe_metadata) = 'object'", name: "rs_billing_settlement_metadata_object"

    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_rated_usage_settlement() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'rated usage settlements are append-only'; END IF;
        IF NOT EXISTS (
          SELECT 1
          FROM recording_studio_billing_rated_usages rated
          JOIN recording_studio_billing_meter_aggregations aggregation ON aggregation.id = rated.meter_aggregation_id
          JOIN recording_studio_billing_financial_commands command ON command.id = NEW.financial_command_id
          JOIN recording_studio_billing_commercial_manifests manifest ON manifest.manifest_digest = NEW.manifest_digest
          WHERE rated.id = NEW.rated_usage_id AND rated.root_recording_id = NEW.root_recording_id
            AND rated.account_recording_id = NEW.account_recording_id AND rated.manifest_digest = NEW.manifest_digest
            AND manifest.used_at IS NOT NULL
            AND command.root_recording_id = NEW.root_recording_id AND command.account_recording_id = NEW.account_recording_id
            AND command.command_type = 'usage_settlement' AND command.provider_account_recording_id = NEW.provider_account_recording_id
            AND command.canonical_request -> 'request' = NEW.canonical_request AND command.request_fingerprint = NEW.request_fingerprint
            AND command.canonical_request #> '{authority,commercial_manifest_digests}' = jsonb_build_array(NEW.manifest_digest)
            AND manifest.canonical_data #>> '{usage_settlement,provider_account_recording_id}' = NEW.provider_account_recording_id::text
            AND NEW.canonical_request ->> 'rated_usage_id' = rated.id::text
            AND NEW.canonical_request ->> 'meter_recording_id' = aggregation.meter_recording_id::text
            AND NEW.canonical_request ->> 'rate_recording_id' = rated.rate_recording_id::text
            AND NEW.canonical_request ->> 'customer_price_recording_id' = rated.customer_price_recording_id::text
            AND NEW.canonical_request ->> 'amount_minor' = rated.customer_amount_minor::text
            AND NEW.canonical_request ->> 'currency' = rated.customer_currency_code
            AND NEW.canonical_request ->> 'currency_exponent' = rated.customer_currency_exponent::text
            AND NEW.canonical_request ->> 'window_starts_at' = to_char(rated.window_starts_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
            AND NEW.canonical_request ->> 'window_ends_at' = to_char(rated.window_ends_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
            AND NEW.canonical_request ->> 'manifest_digest' = rated.manifest_digest
            AND NEW.canonical_request ->> 'market_recording_id' = manifest.canonical_data #>> '{usage_settlement,market_recording_id}'
            AND NEW.canonical_request ->> 'collection_method' = manifest.canonical_data #>> '{usage_settlement,collection_method}'
        ) OR NOT rs_billing_safe_financial_json(NEW.canonical_request) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN
          RAISE EXCEPTION 'rated usage settlement source authority is invalid';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_rated_usage_settlement_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_rated_usage_settlements
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_rated_usage_settlement();
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS rs_billing_protect_rated_usage_settlement() CASCADE"
    drop_table :recording_studio_billing_rated_usage_settlements
  end
end