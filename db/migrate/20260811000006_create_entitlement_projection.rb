# frozen_string_literal: true

class CreateEntitlementProjection < ActiveRecord::Migration[8.1]
  GRANT_SOURCE_TYPES = %w[RecordingStudioBilling::SubscriptionItemVersion RecordingStudioBilling::PurchaseEffect].freeze
  FEATURE_KINDS = %w[boolean limit allowance variant].freeze

  def change
    create_table :recording_studio_billing_entitlement_grants, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.string :source_type, null: false
      t.uuid :source_id, null: false
      t.string :manifest_digest, null: false
      t.string :feature_key, null: false
      t.string :feature_kind, null: false
      t.string :merge_rule, null: false
      t.jsonb :value, null: false
      t.datetime :projected_at, null: false
      t.timestamps
    end
    add_index :recording_studio_billing_entitlement_grants,
              %i[root_recording_id source_type source_id feature_key], unique: true,
              name: "idx_rs_billing_entitlement_grant_source_feature"
    add_index :recording_studio_billing_entitlement_grants, %i[root_recording_id account_recording_id feature_key],
              name: "idx_rs_billing_entitlement_grants_access"
    add_check_constraint :recording_studio_billing_entitlement_grants,
                         "source_type IN (#{quoted(GRANT_SOURCE_TYPES)})",
                         name: "rs_billing_entitlement_grant_source_type"
    add_check_constraint :recording_studio_billing_entitlement_grants,
                         "feature_kind IN (#{quoted(FEATURE_KINDS)})",
                         name: "rs_billing_entitlement_grant_feature_kind"
    add_check_constraint :recording_studio_billing_entitlement_grants,
               "merge_rule IN ('replace', 'minimum', 'maximum', 'merge', 'append')",
               name: "rs_billing_entitlement_grant_merge_rule"
    add_check_constraint :recording_studio_billing_entitlement_grants,
                         "manifest_digest ~ '^[0-9a-f]{64}$'",
                         name: "rs_billing_entitlement_grant_digest"
    add_check_constraint :recording_studio_billing_entitlement_grants,
                         "jsonb_typeof(value) IS NOT NULL",
                         name: "rs_billing_entitlement_grant_value"

    create_table :recording_studio_billing_credit_ledger_entries, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :purchase_effect, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_purchase_effects }
      t.uuid :product_recording_id, null: false
      t.string :manifest_digest, null: false
      t.string :credit_key, null: false
      t.bigint :amount, null: false
      t.datetime :effective_at, null: false
      t.timestamps
    end
    add_index :recording_studio_billing_credit_ledger_entries, %i[purchase_effect_id credit_key], unique: true,
              name: "idx_rs_billing_credit_ledger_effect_key"
    add_index :recording_studio_billing_credit_ledger_entries, %i[root_recording_id account_recording_id credit_key],
              name: "idx_rs_billing_credit_ledger_balance"
    add_check_constraint :recording_studio_billing_credit_ledger_entries,
                         "manifest_digest ~ '^[0-9a-f]{64}$'",
                         name: "rs_billing_credit_ledger_digest"
    add_check_constraint :recording_studio_billing_credit_ledger_entries, "amount > 0",
               name: "rs_billing_credit_ledger_amount"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION rs_billing_protect_entitlement_projection() RETURNS trigger AS $$
          BEGIN
            IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'entitlement projections are append-only'; END IF;
            IF NOT EXISTS (
              SELECT 1
              FROM recording_studio_recordings root
              JOIN recording_studio_recordings account_recording ON account_recording.id = NEW.account_recording_id
              JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
              WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL
                AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = root.id AND account_recording.parent_recording_id = root.id AND account_recording.trashed_at IS NULL AND account.root_recording_id = root.id
            ) THEN RAISE EXCEPTION 'entitlement root or account authority is invalid'; END IF;
            IF NEW.source_type = 'RecordingStudioBilling::SubscriptionItemVersion' AND NOT EXISTS (
              SELECT 1 FROM recording_studio_billing_subscription_item_versions source
              JOIN recording_studio_billing_subscriptions subscription ON subscription.id = source.subscription_id
              WHERE source.id = NEW.source_id AND source.root_recording_id = NEW.root_recording_id AND source.account_recording_id = NEW.account_recording_id AND source.manifest_digest = NEW.manifest_digest AND subscription.root_recording_id = NEW.root_recording_id AND subscription.account_recording_id = NEW.account_recording_id
            ) THEN RAISE EXCEPTION 'entitlement subscription source authority is invalid'; END IF;
            IF NEW.source_type = 'RecordingStudioBilling::SubscriptionItemVersion' AND NOT EXISTS (
              SELECT 1 FROM recording_studio_billing_subscription_item_versions source
              WHERE source.id = NEW.source_id AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'type'] = to_jsonb(NEW.feature_kind)
                AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'merge_rule'] = to_jsonb(NEW.merge_rule)
                AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'value'] = NEW.value
            ) THEN RAISE EXCEPTION 'entitlement subscription grant does not match frozen source'; END IF;
            IF NEW.source_type = 'RecordingStudioBilling::PurchaseEffect' AND NOT EXISTS (
              SELECT 1 FROM recording_studio_billing_purchase_effects source
              JOIN recording_studio_billing_purchases purchase ON purchase.id = source.purchase_id
              WHERE source.id = NEW.source_id AND source.root_recording_id = NEW.root_recording_id AND source.account_recording_id = NEW.account_recording_id AND source.manifest_digest = NEW.manifest_digest AND purchase.manifest_digest = NEW.manifest_digest
            ) THEN RAISE EXCEPTION 'entitlement purchase effect source authority is invalid'; END IF;
            IF NEW.source_type = 'RecordingStudioBilling::PurchaseEffect' AND NOT EXISTS (
              SELECT 1 FROM recording_studio_billing_purchase_effects source
              JOIN recording_studio_billing_purchases purchase ON purchase.id = source.purchase_id
              WHERE source.id = NEW.source_id AND purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'type'] = to_jsonb(NEW.feature_kind)
                AND purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'merge_rule'] = to_jsonb(NEW.merge_rule)
                AND purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'value'] = NEW.value
            ) THEN RAISE EXCEPTION 'entitlement purchase grant does not match frozen source'; END IF;
            IF NOT rs_billing_safe_financial_json(jsonb_build_object('value', NEW.value)) THEN RAISE EXCEPTION 'entitlement grant contains unsafe data'; END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_entitlement_grant_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_entitlement_grants FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_entitlement_projection();

          CREATE FUNCTION rs_billing_protect_credit_ledger_entry() RETURNS trigger AS $$
          BEGIN
            IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'credit ledger entries are append-only'; END IF;
            IF NOT EXISTS (
              SELECT 1 FROM recording_studio_billing_purchase_effects effect
              JOIN recording_studio_billing_purchases purchase ON purchase.id = effect.purchase_id
              WHERE effect.id = NEW.purchase_effect_id AND effect.effect_kind = 'credit_pack'
                AND effect.root_recording_id = NEW.root_recording_id AND effect.account_recording_id = NEW.account_recording_id
                AND effect.manifest_digest = NEW.manifest_digest AND purchase.manifest_digest = NEW.manifest_digest
                AND purchase.product_recording_id = NEW.product_recording_id
                AND purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.credit_key, 'definition', 'type'] = '"allowance"'::jsonb
                AND jsonb_typeof(purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.credit_key, 'value']) = 'number'
                AND (purchase.commercial_snapshot #>> ARRAY['canonical_data', 'features', NEW.credit_key, 'value'])::bigint * purchase.quantity = NEW.amount
            ) THEN RAISE EXCEPTION 'credit ledger source authority is invalid'; END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_credit_ledger_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_credit_ledger_entries FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_credit_ledger_entry();
        SQL
      end
      direction.down do
        execute "DROP FUNCTION IF EXISTS rs_billing_protect_entitlement_projection() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_protect_credit_ledger_entry() CASCADE"
      end
    end
  end

  private

  def quoted(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end
end