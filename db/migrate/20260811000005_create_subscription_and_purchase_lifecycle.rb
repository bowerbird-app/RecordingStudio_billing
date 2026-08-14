# frozen_string_literal: true

class CreateSubscriptionAndPurchaseLifecycle < ActiveRecord::Migration[8.1]
  SUBSCRIPTION_STATES = %w[trialing active past_due paused cancelled expired].freeze
  ITEM_MODES = %w[free_plan monthly_subscription annual_subscription trial_subscription recurring_addon].freeze
  PURCHASE_MODES = %w[one_off_addon one_off_credit_pack].freeze

  def change
    create_table :recording_studio_billing_subscriptions, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.uuid :identifier, null: false, default: -> { "gen_random_uuid()" }
      t.string :state, null: false
      t.string :provider_reference
      t.timestamps
    end
    add_index :recording_studio_billing_subscriptions, :identifier, unique: true,
                                                                    name: "idx_rs_billing_subscriptions_identifier"
    add_index :recording_studio_billing_subscriptions, %i[root_recording_id account_recording_id], unique: true,
                                                                                                   name: "idx_rs_billing_subscription_account"
    add_check_constraint :recording_studio_billing_subscriptions, "state IN (#{quoted(SUBSCRIPTION_STATES)})",
                         name: "rs_billing_subscriptions_state"

    create_table :recording_studio_billing_subscription_item_versions, id: :uuid do |t|
      t.references :subscription, null: false, type: :uuid,
                                  foreign_key: { to_table: :recording_studio_billing_subscriptions }
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :checkout_intent, null: false, type: :uuid,
                                     foreign_key: { to_table: :recording_studio_billing_checkout_intents }
      t.uuid :checkout_intent_item_id, null: false
      t.string :line_key, null: false
      t.integer :version_number, null: false
      t.uuid :product_recording_id, null: false
      t.uuid :billing_option_recording_id, null: false
      t.uuid :price_recording_id, null: false
      t.uuid :provider_account_recording_id, null: false
      t.string :provider_adapter_key, null: false
      t.string :mode, null: false
      t.string :currency_code, null: false
      t.bigint :amount_minor, null: false
      t.integer :quantity, null: false
      t.string :interval
      t.integer :interval_count
      t.string :manifest_digest, null: false
      t.jsonb :commercial_snapshot, null: false
      t.datetime :effective_starts_at, null: false
      t.datetime :effective_ends_at
      t.datetime :superseded_at
      t.timestamps
    end
    add_index :recording_studio_billing_subscription_item_versions, %i[subscription_id line_key version_number],
              unique: true, name: "idx_rs_billing_subscription_item_line_version"
    add_index :recording_studio_billing_subscription_item_versions, :checkout_intent_item_id, unique: true,
                                                                                              name: "idx_rs_billing_subscription_item_checkout_item"
    add_check_constraint :recording_studio_billing_subscription_item_versions, "mode IN (#{quoted(ITEM_MODES)})",
                         name: "rs_billing_subscription_item_modes"
    add_check_constraint :recording_studio_billing_subscription_item_versions,
                         "line_key ~ '^[0-9a-f-]{36}(:[0-9a-f-]{36})?$'", name: "rs_billing_subscription_item_line_key"
    add_check_constraint :recording_studio_billing_subscription_item_versions, "currency_code ~ '^[A-Z]{3}$'",
                         name: "rs_billing_subscription_item_currency"
    add_check_constraint :recording_studio_billing_subscription_item_versions, "amount_minor >= 0 AND quantity > 0",
                         name: "rs_billing_subscription_item_amount_quantity"
    add_check_constraint :recording_studio_billing_subscription_item_versions, "manifest_digest ~ '^[0-9a-f]{64}$'",
                         name: "rs_billing_subscription_item_digest"
    add_check_constraint :recording_studio_billing_subscription_item_versions,
                         "jsonb_typeof(commercial_snapshot) = 'object'", name: "rs_billing_subscription_item_snapshot_object"
    add_check_constraint :recording_studio_billing_subscription_item_versions,
                         "effective_ends_at IS NULL OR effective_ends_at >= effective_starts_at", name: "rs_billing_subscription_item_dates"

    create_table :recording_studio_billing_purchases, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :checkout_intent, null: false, type: :uuid,
                                     foreign_key: { to_table: :recording_studio_billing_checkout_intents }
      t.uuid :checkout_intent_item_id, null: false
      t.uuid :product_recording_id, null: false
      t.uuid :billing_option_recording_id, null: false
      t.uuid :price_recording_id, null: false
      t.uuid :provider_account_recording_id, null: false
      t.string :provider_adapter_key, null: false
      t.string :mode, null: false
      t.string :currency_code, null: false
      t.bigint :amount_minor, null: false
      t.integer :quantity, null: false
      t.string :manifest_digest, null: false
      t.jsonb :commercial_snapshot, null: false
      t.datetime :completed_at, null: false
      t.timestamps
    end
    add_index :recording_studio_billing_purchases, :checkout_intent_item_id, unique: true,
                                                                             name: "idx_rs_billing_purchase_checkout_item"
    add_check_constraint :recording_studio_billing_purchases, "mode IN (#{quoted(PURCHASE_MODES)})",
                         name: "rs_billing_purchase_modes"
    add_check_constraint :recording_studio_billing_purchases, "currency_code ~ '^[A-Z]{3}$'",
                         name: "rs_billing_purchase_currency"
    add_check_constraint :recording_studio_billing_purchases, "amount_minor >= 0 AND quantity > 0",
                         name: "rs_billing_purchase_amount_quantity"
    add_check_constraint :recording_studio_billing_purchases, "manifest_digest ~ '^[0-9a-f]{64}$'",
                         name: "rs_billing_purchase_digest"
    add_check_constraint :recording_studio_billing_purchases, "jsonb_typeof(commercial_snapshot) = 'object'",
                         name: "rs_billing_purchase_snapshot_object"

    create_table :recording_studio_billing_purchase_effects, id: :uuid do |t|
      t.references :purchase, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_purchases }
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.string :effect_kind, null: false
      t.string :idempotency_key, null: false
      t.string :manifest_digest, null: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.datetime :effective_at, null: false
      t.timestamps
    end
    add_index :recording_studio_billing_purchase_effects, %i[root_recording_id idempotency_key], unique: true,
                                                                                                 name: "idx_rs_billing_purchase_effect_idempotency"
    add_check_constraint :recording_studio_billing_purchase_effects, "effect_kind IN ('one_off_addon', 'credit_pack')",
                         name: "rs_billing_purchase_effect_kind"
    add_check_constraint :recording_studio_billing_purchase_effects, "manifest_digest ~ '^[0-9a-f]{64}$'",
                         name: "rs_billing_purchase_effect_digest"
    add_check_constraint :recording_studio_billing_purchase_effects, "jsonb_typeof(safe_metadata) = 'object'",
                         name: "rs_billing_purchase_effect_metadata_object"

    reversible do |direction|
      direction.up { create_lifecycle_functions }
      direction.down do
        %w[rs_billing_subscription_lifecycle rs_billing_protect_subscription_item_version
           rs_billing_validate_lifecycle_projection rs_billing_protect_purchase rs_billing_protect_purchase_effect].each do |name|
          execute "DROP FUNCTION IF EXISTS #{name}() CASCADE"
        end
      end
    end
  end

  private

  def create_lifecycle_functions
    execute <<~SQL
      CREATE FUNCTION rs_billing_validate_lifecycle_projection() RETURNS trigger AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_recordings root
          JOIN recording_studio_recordings account_recording ON account_recording.id = NEW.account_recording_id
          JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
          WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL
            AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = root.id AND account_recording.parent_recording_id = root.id AND account_recording.trashed_at IS NULL AND account.root_recording_id = root.id
        ) THEN RAISE EXCEPTION 'lifecycle root or account authority is invalid'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_subscription_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_subscriptions FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_lifecycle_projection();
      CREATE TRIGGER rs_billing_purchase_authority BEFORE INSERT ON recording_studio_billing_purchases FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_lifecycle_projection();

      CREATE FUNCTION rs_billing_subscription_lifecycle() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'subscriptions are durable'; END IF;
        IF OLD.root_recording_id IS DISTINCT FROM NEW.root_recording_id OR OLD.account_recording_id IS DISTINCT FROM NEW.account_recording_id OR OLD.identifier IS DISTINCT FROM NEW.identifier OR OLD.provider_reference IS DISTINCT FROM NEW.provider_reference THEN RAISE EXCEPTION 'subscription authority is immutable'; END IF;
        IF NOT ((OLD.state = 'trialing' AND NEW.state IN ('active', 'paused', 'cancelled', 'expired')) OR (OLD.state = 'active' AND NEW.state IN ('past_due', 'paused', 'cancelled', 'expired')) OR (OLD.state = 'past_due' AND NEW.state IN ('active', 'paused', 'cancelled', 'expired')) OR (OLD.state = 'paused' AND NEW.state IN ('active', 'cancelled', 'expired')) OR (OLD.state = 'cancelled' AND NEW.state = 'active') OR OLD.state = NEW.state) THEN RAISE EXCEPTION 'subscription lifecycle transition is invalid'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_subscription_lifecycle BEFORE UPDATE OR DELETE ON recording_studio_billing_subscriptions FOR EACH ROW EXECUTE FUNCTION rs_billing_subscription_lifecycle();

      CREATE FUNCTION rs_billing_protect_subscription_item_version() RETURNS trigger AS $$
      DECLARE expected_version integer;
      BEGIN
        IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'subscription item versions are append-only'; END IF;
        IF TG_OP = 'INSERT' THEN
          IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_subscriptions subscription JOIN recording_studio_billing_checkout_intents intent ON intent.id = NEW.checkout_intent_id JOIN recording_studio_billing_checkout_intent_items item ON item.id = NEW.checkout_intent_item_id WHERE subscription.id = NEW.subscription_id AND subscription.root_recording_id = NEW.root_recording_id AND subscription.account_recording_id = NEW.account_recording_id AND intent.root_recording_id = NEW.root_recording_id AND intent.account_recording_id = NEW.account_recording_id AND item.checkout_intent_id = intent.id AND item.manifest_digest = NEW.manifest_digest AND EXISTS (SELECT 1 FROM recording_studio_billing_commercial_manifests manifest WHERE manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL)) THEN RAISE EXCEPTION 'subscription item version source authority is invalid'; END IF;
          IF NEW.line_key <> (CASE WHEN NEW.mode = 'recurring_addon' THEN NEW.product_recording_id::text || ':' || NEW.billing_option_recording_id::text ELSE NEW.product_recording_id::text END) THEN RAISE EXCEPTION 'subscription item version line identity is invalid'; END IF;
          SELECT COALESCE(MAX(version_number), 0) + 1 INTO expected_version FROM recording_studio_billing_subscription_item_versions WHERE subscription_id = NEW.subscription_id AND line_key = NEW.line_key;
          IF NEW.version_number IS DISTINCT FROM expected_version THEN RAISE EXCEPTION 'subscription item versions must be sequential'; END IF;
          IF NOT rs_billing_safe_financial_json(NEW.commercial_snapshot) THEN RAISE EXCEPTION 'subscription item version contains unsafe data'; END IF;
          RETURN NEW;
        END IF;
        IF (to_jsonb(OLD) - 'effective_ends_at' - 'superseded_at' - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'effective_ends_at' - 'superseded_at' - 'updated_at') OR OLD.effective_ends_at IS NOT NULL OR NEW.effective_ends_at IS NULL THEN RAISE EXCEPTION 'subscription item version history is immutable'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_subscription_item_version_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_subscription_item_versions FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_subscription_item_version();

      CREATE FUNCTION rs_billing_protect_purchase() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'purchases are immutable'; END IF;
        IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_checkout_intents intent JOIN recording_studio_billing_checkout_intent_items item ON item.id = NEW.checkout_intent_item_id WHERE intent.id = NEW.checkout_intent_id AND intent.root_recording_id = NEW.root_recording_id AND intent.account_recording_id = NEW.account_recording_id AND item.checkout_intent_id = intent.id AND item.manifest_digest = NEW.manifest_digest AND EXISTS (SELECT 1 FROM recording_studio_billing_commercial_manifests manifest WHERE manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL)) THEN RAISE EXCEPTION 'purchase source authority is invalid'; END IF;
        IF NOT rs_billing_safe_financial_json(NEW.commercial_snapshot) THEN RAISE EXCEPTION 'purchase contains unsafe data'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_purchase_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_purchases FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_purchase();

      CREATE FUNCTION rs_billing_protect_purchase_effect() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'purchase effects are append-only'; END IF;
        IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_purchases purchase WHERE purchase.id = NEW.purchase_id AND purchase.root_recording_id = NEW.root_recording_id AND purchase.account_recording_id = NEW.account_recording_id AND purchase.manifest_digest = NEW.manifest_digest) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN RAISE EXCEPTION 'purchase effect authority or payload is invalid'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_purchase_effect_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_purchase_effects FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_purchase_effect();
    SQL
  end

  def quoted(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end
end
