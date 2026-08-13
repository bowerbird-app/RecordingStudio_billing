# frozen_string_literal: true

class CreateMeterAggregationsAndRatedUsage < ActiveRecord::Migration[8.1]
  def up
    create_table :recording_studio_billing_meter_aggregations, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.uuid :meter_recording_id, null: false
      t.uuid :usage_unit_recording_id, null: false
      t.string :manifest_digest, null: false
      t.string :aggregation, null: false
      t.datetime :window_starts_at, null: false
      t.datetime :window_ends_at, null: false
      t.datetime :aggregated_at, null: false
      t.bigint :quantity, null: false
      t.integer :event_count, null: false
      t.uuid :usage_event_ids, array: true, null: false, default: []
      t.string :input_digest, null: false
      t.jsonb :input_snapshot, null: false, default: {}
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_meter_aggregations,
              %i[root_recording_id account_recording_id meter_recording_id window_starts_at window_ends_at manifest_digest input_digest],
              unique: true, name: "idx_rs_billing_meter_aggregation_input"
    add_check_constraint :recording_studio_billing_meter_aggregations, "aggregation IN ('sum', 'count', 'maximum', 'latest')",
                         name: "rs_billing_meter_aggregation_mode"
    add_check_constraint :recording_studio_billing_meter_aggregations, "window_ends_at > window_starts_at",
                         name: "rs_billing_meter_aggregation_window"
    add_check_constraint :recording_studio_billing_meter_aggregations, "event_count > 0",
                         name: "rs_billing_meter_aggregation_events"
    add_check_constraint :recording_studio_billing_meter_aggregations, "cardinality(usage_event_ids) = event_count",
                         name: "rs_billing_meter_aggregation_event_ids"
    add_check_constraint :recording_studio_billing_meter_aggregations, "jsonb_typeof(input_snapshot) = 'object'",
                         name: "rs_billing_meter_aggregation_input_object"
    add_check_constraint :recording_studio_billing_meter_aggregations, "jsonb_typeof(safe_metadata) = 'object'",
                         name: "rs_billing_meter_aggregation_metadata_object"

    create_table :recording_studio_billing_rated_usages, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :meter_aggregation, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_meter_aggregations }
      t.string :manifest_digest, null: false
      t.uuid :rate_recording_id, null: false
      t.uuid :customer_price_recording_id, null: false
      t.uuid :cost_rate_recording_id
      t.uuid :rate_card_recording_id, null: false
      t.uuid :cost_card_recording_id
      t.bigint :quantity, null: false
      t.bigint :customer_amount_minor
      t.string :customer_currency_code
      t.integer :customer_currency_exponent
      t.bigint :cost_amount_minor
      t.string :cost_currency_code
      t.integer :cost_currency_exponent
      t.datetime :window_starts_at, null: false
      t.datetime :window_ends_at, null: false
      t.datetime :rated_at, null: false
      t.jsonb :aggregation_snapshot, null: false, default: {}
      t.jsonb :rate_snapshot, null: false, default: {}
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_rated_usages, :meter_aggregation_id, unique: true,
                                                                             name: "idx_rs_billing_rated_usage_aggregation"
    add_check_constraint :recording_studio_billing_rated_usages, "window_ends_at > window_starts_at",
                         name: "rs_billing_rated_usage_window"
    add_check_constraint :recording_studio_billing_rated_usages, "quantity >= 0",
                         name: "rs_billing_rated_usage_quantity"
    add_check_constraint :recording_studio_billing_rated_usages,
                         "(customer_amount_minor IS NULL AND customer_currency_code IS NULL AND customer_currency_exponent IS NULL) OR (customer_amount_minor >= 0 AND customer_currency_code ~ '^[A-Z]{3}$' AND customer_currency_exponent BETWEEN 0 AND 3)",
                         name: "rs_billing_rated_usage_customer_money"
    add_check_constraint :recording_studio_billing_rated_usages,
                         "(cost_amount_minor IS NULL AND cost_currency_code IS NULL AND cost_currency_exponent IS NULL) OR (cost_amount_minor >= 0 AND cost_currency_code ~ '^[A-Z]{3}$' AND cost_currency_exponent BETWEEN 0 AND 3)",
                         name: "rs_billing_rated_usage_cost_money"
    add_check_constraint :recording_studio_billing_rated_usages, "jsonb_typeof(aggregation_snapshot) = 'object'",
                         name: "rs_billing_rated_usage_aggregation_object"
    add_check_constraint :recording_studio_billing_rated_usages, "jsonb_typeof(rate_snapshot) = 'object'",
                         name: "rs_billing_rated_usage_rate_object"
    add_check_constraint :recording_studio_billing_rated_usages, "jsonb_typeof(safe_metadata) = 'object'",
                         name: "rs_billing_rated_usage_metadata_object"

    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_meter_aggregation() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'meter aggregations are append-only'; END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_recordings root
          JOIN recording_studio_recordings account_recording ON account_recording.id = NEW.account_recording_id
          JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
          WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL
            AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = root.id AND account_recording.parent_recording_id = root.id AND account_recording.trashed_at IS NULL AND account.root_recording_id = root.id
        ) OR NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_commercial_manifests manifest
          WHERE manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL
            AND manifest.canonical_data #> ARRAY['usage_rating', 'meters', NEW.meter_recording_id::text, 'usage_unit_recording_id'] = to_jsonb(NEW.usage_unit_recording_id::text)
            AND manifest.canonical_data #> ARRAY['usage_rating', 'meters', NEW.meter_recording_id::text, 'aggregation'] = to_jsonb(NEW.aggregation)
            AND NEW.input_snapshot ->> 'meter_recording_id' = NEW.meter_recording_id::text
            AND NEW.input_snapshot ->> 'usage_unit_recording_id' = NEW.usage_unit_recording_id::text
            AND NEW.input_snapshot ->> 'aggregation' = NEW.aggregation
            AND NEW.input_snapshot ->> 'window_starts_at' = to_char(NEW.window_starts_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
            AND NEW.input_snapshot ->> 'window_ends_at' = to_char(NEW.window_ends_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
            AND NEW.usage_event_ids = ARRAY(
              SELECT event.id FROM recording_studio_billing_usage_events event
              WHERE event.root_recording_id = NEW.root_recording_id AND event.account_recording_id = NEW.account_recording_id
                AND event.usage_key = manifest.canonical_data #>> ARRAY['usage_rating', 'meters', NEW.meter_recording_id::text, 'usage_key']
                AND event.occurred_at >= NEW.window_starts_at AND event.occurred_at < NEW.window_ends_at
              ORDER BY event.occurred_at, event.id
            )
            AND NEW.input_snapshot -> 'events' = COALESCE((
              SELECT jsonb_agg(jsonb_build_object('id', event.id::text, 'quantity', event.quantity) ORDER BY event.occurred_at, event.id)
              FROM recording_studio_billing_usage_events event WHERE event.id = ANY(NEW.usage_event_ids)
            ), '[]'::jsonb)
            AND NEW.quantity = CASE NEW.aggregation
              WHEN 'sum' THEN (SELECT SUM(event.quantity) FROM recording_studio_billing_usage_events event WHERE event.id = ANY(NEW.usage_event_ids))
              WHEN 'count' THEN cardinality(NEW.usage_event_ids)
              WHEN 'maximum' THEN (SELECT MAX(event.quantity) FROM recording_studio_billing_usage_events event WHERE event.id = ANY(NEW.usage_event_ids))
              WHEN 'latest' THEN (SELECT event.quantity FROM recording_studio_billing_usage_events event WHERE event.id = ANY(NEW.usage_event_ids) ORDER BY event.occurred_at DESC, event.id DESC LIMIT 1)
            END
            AND NEW.input_digest = encode(digest(NEW.input_snapshot::text, 'sha256'), 'hex')
        ) OR NOT rs_billing_safe_financial_json(NEW.input_snapshot) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN
          RAISE EXCEPTION 'meter aggregation source authority is invalid';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_meter_aggregation_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_meter_aggregations FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_meter_aggregation();

      CREATE FUNCTION rs_billing_protect_rated_usage() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'rated usages are append-only'; END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_meter_aggregations aggregation
          JOIN recording_studio_billing_commercial_manifests manifest ON manifest.manifest_digest = NEW.manifest_digest
          WHERE aggregation.id = NEW.meter_aggregation_id AND aggregation.root_recording_id = NEW.root_recording_id
            AND aggregation.account_recording_id = NEW.account_recording_id AND aggregation.manifest_digest = NEW.manifest_digest
            AND aggregation.window_starts_at = NEW.window_starts_at AND aggregation.window_ends_at = NEW.window_ends_at
            AND manifest.used_at IS NOT NULL
            AND NEW.aggregation_snapshot = aggregation.input_snapshot
            AND NEW.rate_snapshot -> 'rate' = manifest.canonical_data #> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text]
            AND NEW.rate_snapshot -> 'customer_rate' = manifest.canonical_data #> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text]
            AND (NEW.cost_rate_recording_id IS NULL OR NEW.rate_snapshot -> 'cost_rate' = manifest.canonical_data #> ARRAY['usage_rating', 'cost_rates', NEW.cost_rate_recording_id::text])
            AND (NEW.cost_rate_recording_id IS NOT NULL OR NEW.rate_snapshot -> 'cost_rate' = 'null'::jsonb)
            AND manifest.canonical_data #> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'rate_card_recording_id'] = to_jsonb(NEW.rate_card_recording_id::text)
            AND manifest.canonical_data #> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'usage_unit_recording_id'] = to_jsonb(aggregation.usage_unit_recording_id::text)
            AND manifest.canonical_data #> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text, 'usage_unit_recording_id'] = to_jsonb(aggregation.usage_unit_recording_id::text)
            AND (NEW.cost_rate_recording_id IS NULL OR manifest.canonical_data #> ARRAY['usage_rating', 'cost_rates', NEW.cost_rate_recording_id::text, 'cost_card_recording_id'] = to_jsonb(NEW.cost_card_recording_id::text))
            AND (NEW.cost_rate_recording_id IS NULL OR manifest.canonical_data #> ARRAY['usage_rating', 'cost_rates', NEW.cost_rate_recording_id::text, 'usage_unit_recording_id'] = to_jsonb(aggregation.usage_unit_recording_id::text))
            AND NEW.quantity = aggregation.quantity * (manifest.canonical_data #>> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'conversion_numerator'])::bigint / (manifest.canonical_data #>> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'conversion_denominator'])::bigint
            AND (aggregation.quantity * (manifest.canonical_data #>> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'conversion_numerator'])::bigint) % (manifest.canonical_data #>> ARRAY['usage_rating', 'rates', NEW.rate_recording_id::text, 'conversion_denominator'])::bigint = 0
            AND NEW.customer_amount_minor = (manifest.canonical_data #>> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text, 'amount_minor'])::bigint * CASE manifest.canonical_data #>> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text, 'pricing_model']
              WHEN 'per_unit' THEN NEW.quantity
              WHEN 'package' THEN NEW.quantity / (manifest.canonical_data #>> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text, 'package_size'])::bigint
            END
            AND (manifest.canonical_data #>> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text, 'pricing_model'] <> 'package' OR NEW.quantity % (manifest.canonical_data #>> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text, 'package_size'])::bigint = 0)
            AND NEW.customer_currency_code = manifest.canonical_data #>> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text, 'currency_code']
            AND NEW.customer_currency_exponent = (manifest.canonical_data #>> ARRAY['usage_rating', 'customer_rates', NEW.customer_price_recording_id::text, 'currency_exponent'])::integer
            AND (NEW.cost_rate_recording_id IS NULL AND NEW.cost_card_recording_id IS NULL AND NEW.cost_amount_minor IS NULL AND NEW.cost_currency_code IS NULL AND NEW.cost_currency_exponent IS NULL OR NEW.cost_rate_recording_id IS NOT NULL AND NEW.cost_amount_minor = NEW.quantity * (manifest.canonical_data #>> ARRAY['usage_rating', 'cost_rates', NEW.cost_rate_recording_id::text, 'amount_minor'])::bigint AND NEW.cost_currency_code = manifest.canonical_data #>> ARRAY['usage_rating', 'cost_rates', NEW.cost_rate_recording_id::text, 'currency_code'] AND NEW.cost_currency_exponent = (manifest.canonical_data #>> ARRAY['usage_rating', 'cost_rates', NEW.cost_rate_recording_id::text, 'currency_exponent'])::integer)
        ) OR NOT rs_billing_safe_financial_json(NEW.aggregation_snapshot) OR NOT rs_billing_safe_financial_json(NEW.rate_snapshot) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN
          RAISE EXCEPTION 'rated usage source authority is invalid';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_rated_usage_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_rated_usages FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_rated_usage();
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS rs_billing_protect_rated_usage() CASCADE"
    execute "DROP FUNCTION IF EXISTS rs_billing_protect_meter_aggregation() CASCADE"
    drop_table :recording_studio_billing_rated_usages
    drop_table :recording_studio_billing_meter_aggregations
  end
end
