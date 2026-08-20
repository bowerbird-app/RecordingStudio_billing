# frozen_string_literal: true

class AddDefaultEntitlementBootstrap < ActiveRecord::Migration[8.1]
  def up
    create_table :recording_studio_billing_default_entitlement_bootstraps, id: :uuid do |t|
      t.uuid :root_recording_id, null: false
      t.uuid :account_recording_id, null: false
      t.string :product_key, null: false
      t.string :manifest_digest, null: false
      t.jsonb :commercial_snapshot, null: false, default: {}
      t.datetime :applied_at, null: false
      t.timestamps
    end

    add_index :recording_studio_billing_default_entitlement_bootstraps,
              %i[root_recording_id account_recording_id],
              unique: true,
              name: "idx_rs_billing_default_entitlement_bootstrap_account"
    add_index :recording_studio_billing_default_entitlement_bootstraps, :root_recording_id
    add_index :recording_studio_billing_default_entitlement_bootstraps, :account_recording_id

    add_foreign_key :recording_studio_billing_default_entitlement_bootstraps, :recording_studio_recordings,
                    column: :root_recording_id
    add_foreign_key :recording_studio_billing_default_entitlement_bootstraps, :recording_studio_recordings,
                    column: :account_recording_id

    execute <<~SQL.squish
      ALTER TABLE recording_studio_billing_entitlement_grants
      DROP CONSTRAINT rs_billing_entitlement_grant_source_type;
    SQL

    execute <<~SQL.squish
      ALTER TABLE recording_studio_billing_entitlement_grants
      ADD CONSTRAINT rs_billing_entitlement_grant_source_type CHECK (
        source_type IN (
          'RecordingStudioBilling::SubscriptionLine',
          'RecordingStudioBilling::Purchase',
          'RecordingStudioBilling::DefaultEntitlementBootstrap'
        )
      );
    SQL

    execute <<~SQL.squish
      CREATE OR REPLACE FUNCTION public.rs_billing_protect_entitlement_projection() RETURNS trigger
          LANGUAGE plpgsql
          AS $$
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
        IF NEW.source_type = 'RecordingStudioBilling::SubscriptionLine' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_subscription_lines source
          JOIN recording_studio_recordings subscription_recording ON subscription_recording.id = source.subscription_recording_id
          JOIN recording_studio_billing_subscriptions subscription ON subscription.id = subscription_recording.recordable_id
          WHERE source.id = NEW.source_id AND source.root_recording_id = NEW.root_recording_id AND source.account_recording_id = NEW.account_recording_id AND source.manifest_digest = NEW.manifest_digest AND subscription_recording.recordable_type = 'RecordingStudioBilling::Subscription' AND subscription.root_recording_id = NEW.root_recording_id AND subscription.account_recording_id = NEW.account_recording_id
        ) THEN RAISE EXCEPTION 'entitlement subscription source authority is invalid'; END IF;
        IF NEW.source_type = 'RecordingStudioBilling::SubscriptionLine' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_subscription_lines source
          WHERE source.id = NEW.source_id AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'type'] = to_jsonb(NEW.feature_kind)
            AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'merge_rule'] = to_jsonb(NEW.merge_rule)
            AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'value'] = NEW.value
        ) THEN RAISE EXCEPTION 'entitlement subscription grant does not match frozen source'; END IF;
        IF NEW.source_type = 'RecordingStudioBilling::Purchase' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_purchases source
          WHERE source.id = NEW.source_id AND source.root_recording_id = NEW.root_recording_id AND source.account_recording_id = NEW.account_recording_id AND source.manifest_digest = NEW.manifest_digest
        ) THEN RAISE EXCEPTION 'entitlement purchase source authority is invalid'; END IF;
        IF NEW.source_type = 'RecordingStudioBilling::Purchase' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_purchases source
          WHERE source.id = NEW.source_id AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'type'] = to_jsonb(NEW.feature_kind)
            AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'merge_rule'] = to_jsonb(NEW.merge_rule)
            AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'value'] = NEW.value
        ) THEN RAISE EXCEPTION 'entitlement purchase grant does not match frozen source'; END IF;
        IF NEW.source_type = 'RecordingStudioBilling::DefaultEntitlementBootstrap' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_default_entitlement_bootstraps source
          WHERE source.id = NEW.source_id AND source.root_recording_id = NEW.root_recording_id AND source.account_recording_id = NEW.account_recording_id AND source.manifest_digest = NEW.manifest_digest
        ) THEN RAISE EXCEPTION 'entitlement bootstrap source authority is invalid'; END IF;
        IF NEW.source_type = 'RecordingStudioBilling::DefaultEntitlementBootstrap' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_default_entitlement_bootstraps source
          WHERE source.id = NEW.source_id AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'type'] = to_jsonb(NEW.feature_kind)
            AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'definition', 'merge_rule'] = to_jsonb(NEW.merge_rule)
            AND source.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.feature_key, 'value'] = NEW.value
        ) THEN RAISE EXCEPTION 'entitlement bootstrap grant does not match frozen source'; END IF;
        IF NOT rs_billing_safe_financial_json(jsonb_build_object('value', NEW.value)) THEN RAISE EXCEPTION 'entitlement grant contains unsafe data'; END IF;
        RETURN NEW;
      END;
      $$;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
