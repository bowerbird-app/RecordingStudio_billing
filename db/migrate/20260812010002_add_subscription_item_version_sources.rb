# frozen_string_literal: true

class AddSubscriptionItemVersionSources < ActiveRecord::Migration[8.1]
  def up
    change_column_null :recording_studio_billing_subscription_item_versions, :checkout_intent_id, true
    change_column_null :recording_studio_billing_subscription_item_versions, :checkout_intent_item_id, true
    add_column :recording_studio_billing_subscription_item_versions, :source_type, :string, null: false,
                                                                                            default: "checkout"
    add_column :recording_studio_billing_subscription_item_versions, :source_id, :uuid
    add_column :recording_studio_billing_subscription_item_versions, :source_snapshot, :jsonb, null: false, default: {}
    execute <<~SQL
      UPDATE recording_studio_billing_subscription_item_versions
      SET source_id = checkout_intent_item_id, source_snapshot = commercial_snapshot
      WHERE source_type = 'checkout';
      ALTER TABLE recording_studio_billing_subscription_item_versions
      ADD CONSTRAINT rs_billing_subscription_item_version_source
      CHECK ((source_type = 'checkout' AND checkout_intent_id IS NOT NULL AND checkout_intent_item_id IS NOT NULL AND source_id IS NOT NULL)
          OR (source_type = 'subscription_change' AND source_id IS NOT NULL));
      DROP TRIGGER rs_billing_subscription_item_version_history ON recording_studio_billing_subscription_item_versions;
      DROP FUNCTION rs_billing_protect_subscription_item_version();
      CREATE FUNCTION rs_billing_protect_subscription_item_version() RETURNS trigger AS $$
      DECLARE expected_version integer;
      BEGIN
        IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'subscription item versions are append-only'; END IF;
        IF TG_OP = 'INSERT' THEN
          IF NEW.source_type = 'checkout' AND NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_checkout_intents intent
            JOIN recording_studio_billing_checkout_intent_items item ON item.id = NEW.checkout_intent_item_id
            WHERE intent.id = NEW.checkout_intent_id AND item.checkout_intent_id = intent.id
              AND intent.root_recording_id = NEW.root_recording_id AND intent.account_recording_id = NEW.account_recording_id
              AND item.manifest_digest = NEW.manifest_digest
              AND item.commercial_manifest = NEW.source_snapshot
              AND item.commercial_manifest = NEW.commercial_snapshot
          ) THEN RAISE EXCEPTION 'checkout source authority is invalid'; END IF;
          IF NEW.source_type = 'subscription_change' AND NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_subscription_change_intents change
            WHERE change.id = NEW.source_id AND change.subscription_id = NEW.subscription_id
              AND change.root_recording_id = NEW.root_recording_id AND change.account_recording_id = NEW.account_recording_id
                  AND (change.proposed_manifest_digest = NEW.manifest_digest
                    OR (change.change_kind = 'resumption' AND change.current_manifest_digest = NEW.manifest_digest))
                  AND change.state = 'applied'
                  AND NEW.source_snapshot = CASE
                    WHEN change.change_kind = 'resumption' THEN change.frozen_terms -> 'current'
                    ELSE change.frozen_terms -> 'proposed'
                  END
                  AND NEW.commercial_snapshot = NEW.source_snapshot
          ) THEN RAISE EXCEPTION 'subscription change source authority is invalid'; END IF;
          SELECT COALESCE(MAX(version_number), 0) + 1 INTO expected_version
          FROM recording_studio_billing_subscription_item_versions WHERE subscription_item_id = NEW.subscription_item_id;
          IF NEW.version_number IS DISTINCT FROM expected_version THEN RAISE EXCEPTION 'subscription item versions must be sequential'; END IF;
          IF NOT rs_billing_safe_financial_json(NEW.commercial_snapshot) OR NOT rs_billing_safe_financial_json(NEW.source_snapshot) THEN RAISE EXCEPTION 'subscription item version contains unsafe data'; END IF;
          RETURN NEW;
        END IF;
        IF (to_jsonb(OLD) - 'effective_ends_at' - 'superseded_at' - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'effective_ends_at' - 'superseded_at' - 'updated_at') OR OLD.effective_ends_at IS NOT NULL OR NEW.effective_ends_at IS NULL THEN RAISE EXCEPTION 'subscription item version history is immutable'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_subscription_item_version_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_subscription_item_versions
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_subscription_item_version();
    SQL
    change_column_null :recording_studio_billing_plan_update_applications, :plan_update_run_id, false
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
