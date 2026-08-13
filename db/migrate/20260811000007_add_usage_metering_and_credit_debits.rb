# frozen_string_literal: true

class AddUsageMeteringAndCreditDebits < ActiveRecord::Migration[8.1]
  def up
    create_table :recording_studio_billing_usage_events, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.string :usage_key, null: false
      t.string :feature_key
      t.uuid :usage_unit_recording_id
      t.bigint :quantity, null: false
      t.datetime :occurred_at, null: false
      t.string :idempotency_key, null: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_usage_events, %i[root_recording_id idempotency_key], unique: true,
                                                                                             name: "idx_rs_billing_usage_event_idempotency"
    add_index :recording_studio_billing_usage_events, %i[root_recording_id account_recording_id usage_key occurred_at],
              name: "idx_rs_billing_usage_event_total"
    add_check_constraint :recording_studio_billing_usage_events, "quantity > 0",
                         name: "rs_billing_usage_event_quantity"
    add_check_constraint :recording_studio_billing_usage_events, "jsonb_typeof(safe_metadata) = 'object'",
                         name: "rs_billing_usage_event_metadata_object"

    change_column_null :recording_studio_billing_credit_ledger_entries, :purchase_effect_id, true
    add_column :recording_studio_billing_credit_ledger_entries, :direction, :string, null: false, default: "credit"
    add_reference :recording_studio_billing_credit_ledger_entries, :usage_event, type: :uuid,
                                                                                 foreign_key: { to_table: :recording_studio_billing_usage_events }
    add_column :recording_studio_billing_credit_ledger_entries, :idempotency_key, :string
    add_column :recording_studio_billing_credit_ledger_entries, :safe_metadata, :jsonb, null: false, default: {}
    remove_check_constraint :recording_studio_billing_credit_ledger_entries, name: "rs_billing_credit_ledger_amount"
    add_check_constraint :recording_studio_billing_credit_ledger_entries,
                         "(direction = 'credit' AND amount > 0 AND purchase_effect_id IS NOT NULL AND usage_event_id IS NULL AND idempotency_key IS NULL) OR (direction = 'debit' AND amount < 0 AND purchase_effect_id IS NULL AND usage_event_id IS NOT NULL AND idempotency_key IS NOT NULL)",
                         name: "rs_billing_credit_ledger_direction_amount"
    add_check_constraint :recording_studio_billing_credit_ledger_entries, "direction IN ('credit', 'debit')",
                         name: "rs_billing_credit_ledger_direction"
    add_check_constraint :recording_studio_billing_credit_ledger_entries, "jsonb_typeof(safe_metadata) = 'object'",
                         name: "rs_billing_credit_ledger_metadata_object"
    add_index :recording_studio_billing_credit_ledger_entries, :usage_event_id, unique: true,
                                                                                name: "idx_rs_billing_credit_ledger_usage_event"
    add_index :recording_studio_billing_credit_ledger_entries, %i[root_recording_id idempotency_key], unique: true,
                                                                                                      where: "direction = 'debit'", name: "idx_rs_billing_credit_debit_idempotency"

    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_usage_event() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'usage events are append-only'; END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_recordings root
          JOIN recording_studio_recordings account_recording ON account_recording.id = NEW.account_recording_id
          JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
          WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL
            AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = root.id AND account_recording.parent_recording_id = root.id AND account_recording.trashed_at IS NULL AND account.root_recording_id = root.id
        ) THEN RAISE EXCEPTION 'usage event root or account authority is invalid'; END IF;
        IF NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN RAISE EXCEPTION 'usage event contains unsafe metadata'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_usage_event_history BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_usage_events FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_usage_event();

      CREATE OR REPLACE FUNCTION rs_billing_protect_credit_ledger_entry() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'credit ledger entries are append-only'; END IF;
        IF NEW.direction = 'credit' THEN
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
        ELSIF NEW.direction = 'debit' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_usage_events event
            WHERE event.id = NEW.usage_event_id AND event.root_recording_id = NEW.root_recording_id
              AND event.account_recording_id = NEW.account_recording_id AND event.usage_key = NEW.credit_key
              AND event.idempotency_key = NEW.idempotency_key
          ) OR NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_credit_ledger_entries credit
            WHERE credit.direction = 'credit' AND credit.root_recording_id = NEW.root_recording_id
              AND credit.account_recording_id = NEW.account_recording_id AND credit.product_recording_id = NEW.product_recording_id
              AND credit.credit_key = NEW.credit_key AND credit.manifest_digest = NEW.manifest_digest
          ) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN
            RAISE EXCEPTION 'credit debit source authority is invalid';
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS rs_billing_protect_usage_event() CASCADE"
    remove_index :recording_studio_billing_credit_ledger_entries, name: "idx_rs_billing_credit_debit_idempotency"
    remove_index :recording_studio_billing_credit_ledger_entries, name: "idx_rs_billing_credit_ledger_usage_event"
    remove_check_constraint :recording_studio_billing_credit_ledger_entries,
                            name: "rs_billing_credit_ledger_metadata_object"
    remove_check_constraint :recording_studio_billing_credit_ledger_entries, name: "rs_billing_credit_ledger_direction"
    remove_check_constraint :recording_studio_billing_credit_ledger_entries,
                            name: "rs_billing_credit_ledger_direction_amount"
    add_check_constraint :recording_studio_billing_credit_ledger_entries, "amount > 0",
                         name: "rs_billing_credit_ledger_amount"
    remove_column :recording_studio_billing_credit_ledger_entries, :safe_metadata
    remove_column :recording_studio_billing_credit_ledger_entries, :idempotency_key
    remove_reference :recording_studio_billing_credit_ledger_entries, :usage_event
    remove_column :recording_studio_billing_credit_ledger_entries, :direction
    change_column_null :recording_studio_billing_credit_ledger_entries, :purchase_effect_id, false
    drop_table :recording_studio_billing_usage_events
  end
end
