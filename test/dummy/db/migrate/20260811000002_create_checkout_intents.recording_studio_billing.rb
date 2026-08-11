# frozen_string_literal: true

# This migration comes from recording_studio_billing (originally 20260811000002)
class CreateCheckoutIntents < ActiveRecord::Migration[8.1]
  INTENT_STATES = %w[draft validated awaiting_confirmation pending_provider requires_requote completed failed cancelled expired requires_review].freeze
  ATTEMPT_STATES = %w[pending processing succeeded failed cancelled unknown].freeze

  def change
    create_table :recording_studio_billing_checkout_intents, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.string :local_idempotency_key, null: false
      t.string :request_fingerprint, null: false
      t.string :state, null: false, default: "draft"
      t.string :advisory_country_code
      t.string :advisory_currency_code
      t.string :presentation_preference
      t.references :financial_command, type: :uuid, foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.timestamps
    end
    add_index :recording_studio_billing_checkout_intents, %i[root_recording_id local_idempotency_key], unique: true, name: "idx_rs_billing_checkout_intent_idempotency"
    add_check_constraint :recording_studio_billing_checkout_intents, "state IN (#{quoted(INTENT_STATES)})", name: "rs_billing_checkout_intents_state"
    add_check_constraint :recording_studio_billing_checkout_intents, "request_fingerprint ~ '^[0-9a-f]{64}$'", name: "rs_billing_checkout_intents_fingerprint"

    create_table :recording_studio_billing_checkout_intent_items, id: :uuid do |t|
      t.references :checkout_intent, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_checkout_intents }
      t.uuid :product_recording_id, null: false
      t.uuid :billing_option_recording_id, null: false
      t.uuid :price_recording_id, null: false
      t.uuid :provider_account_recording_id, null: false
      t.uuid :market_recording_id, null: false
      t.string :product_recordable_type, null: false
      t.uuid :product_recordable_id, null: false
      t.string :billing_option_recordable_type, null: false
      t.uuid :billing_option_recordable_id, null: false
      t.integer :quantity, null: false
      t.string :currency_code, null: false
      t.string :collection_method, null: false
      t.string :presentation, null: false
      t.jsonb :commercial_manifest, null: false
      t.string :manifest_digest, null: false
      t.timestamps
    end
    add_index :recording_studio_billing_checkout_intent_items, %i[checkout_intent_id billing_option_recording_id], unique: true, name: "idx_rs_billing_checkout_items_option"
    add_check_constraint :recording_studio_billing_checkout_intent_items, "quantity > 0", name: "rs_billing_checkout_items_quantity"
    add_check_constraint :recording_studio_billing_checkout_intent_items, "currency_code ~ '^[A-Z]{3}$'", name: "rs_billing_checkout_items_currency"
    add_check_constraint :recording_studio_billing_checkout_intent_items, "presentation IN ('embedded', 'redirect', 'payment_link', 'invoice', 'no_charge')", name: "rs_billing_checkout_items_presentation"
    add_check_constraint :recording_studio_billing_checkout_intent_items, "manifest_digest ~ '^[0-9a-f]{64}$'", name: "rs_billing_checkout_items_digest"
    add_check_constraint :recording_studio_billing_checkout_intent_items, "jsonb_typeof(commercial_manifest) = 'object'", name: "rs_billing_checkout_items_manifest_object"

    create_table :recording_studio_billing_checkout_attempts, id: :uuid do |t|
      t.references :checkout_intent, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_checkout_intents }
      t.references :financial_command, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.integer :attempt_number, null: false
      t.string :state, null: false
      t.jsonb :safe_result, null: false, default: {}
      t.jsonb :safe_error_details, null: false, default: {}
      t.datetime :completed_at
      t.timestamps
    end
    add_index :recording_studio_billing_checkout_attempts, %i[checkout_intent_id attempt_number], unique: true, name: "idx_rs_billing_checkout_attempt_number"
    add_check_constraint :recording_studio_billing_checkout_attempts, "attempt_number > 0", name: "rs_billing_checkout_attempts_number"
    add_check_constraint :recording_studio_billing_checkout_attempts, "state IN (#{quoted(ATTEMPT_STATES)})", name: "rs_billing_checkout_attempts_state"
    add_check_constraint :recording_studio_billing_checkout_attempts, "jsonb_typeof(safe_result) = 'object'", name: "rs_billing_checkout_attempts_result_object"
    add_check_constraint :recording_studio_billing_checkout_attempts, "jsonb_typeof(safe_error_details) = 'object'", name: "rs_billing_checkout_attempts_error_object"
    add_check_constraint :recording_studio_billing_checkout_attempts, "(state IN ('pending', 'processing') AND completed_at IS NULL) OR (state IN ('succeeded', 'failed', 'cancelled', 'unknown') AND completed_at IS NOT NULL)", name: "rs_billing_checkout_attempts_lifecycle"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION rs_billing_validate_checkout_authority() RETURNS trigger AS $$
          BEGIN
            IF NOT EXISTS (SELECT 1 FROM recording_studio_recordings root WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL AND root.root_recording_id = root.id AND root.trashed_at IS NULL) THEN
              RAISE EXCEPTION 'checkout intent root authority is invalid';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM recording_studio_recordings account_recording JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id WHERE account_recording.id = NEW.account_recording_id AND account_recording.recordable_type = 'RecordingStudioBilling::Account' AND account_recording.root_recording_id = NEW.root_recording_id AND account_recording.parent_recording_id = NEW.root_recording_id AND account_recording.trashed_at IS NULL AND account.root_recording_id = NEW.root_recording_id) THEN
              RAISE EXCEPTION 'checkout intent account authority is invalid';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_checkout_intent_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_checkout_intents FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_checkout_authority();
          CREATE FUNCTION rs_billing_validate_checkout_command_binding() RETURNS trigger AS $$
          BEGIN
            IF NEW.financial_command_id IS NOT NULL AND EXISTS (
              SELECT 1
              FROM recording_studio_billing_checkout_intent_items item
              JOIN recording_studio_billing_financial_commands command ON command.id = NEW.financial_command_id
              WHERE item.checkout_intent_id = NEW.id
                AND NOT (command.canonical_request -> 'authority' -> 'commercial_manifest_digests' ? item.manifest_digest)
            ) THEN
              RAISE EXCEPTION 'checkout command must bind every frozen manifest digest';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_checkout_intent_command_binding BEFORE UPDATE OF financial_command_id ON recording_studio_billing_checkout_intents FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_checkout_command_binding();
          CREATE FUNCTION rs_billing_validate_checkout_execution_state() RETURNS trigger AS $$
          BEGIN
            IF NEW.state IN ('requires_requote', 'requires_review', 'cancelled', 'expired') AND EXISTS (
              SELECT 1 FROM recording_studio_billing_financial_commands command
              WHERE command.id = NEW.financial_command_id AND command.state IN ('pending', 'processing')
            ) THEN
              RAISE EXCEPTION 'non-executable checkout intent cannot retain an executable command';
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_checkout_intent_execution_state BEFORE UPDATE OF state ON recording_studio_billing_checkout_intents FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_checkout_execution_state();
          CREATE FUNCTION rs_billing_protect_checkout_item() RETURNS trigger AS $$
          BEGIN RAISE EXCEPTION 'checkout intent items are immutable'; END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_checkout_item_history BEFORE UPDATE OR DELETE ON recording_studio_billing_checkout_intent_items FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_checkout_item();
          CREATE FUNCTION rs_billing_protect_checkout_attempt() RETURNS trigger AS $$
          DECLARE expected_attempt_number integer;
          BEGIN
            IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'checkout attempts are append-only'; END IF;
            IF NOT EXISTS (SELECT 1 FROM recording_studio_billing_checkout_intents intent WHERE intent.id = NEW.checkout_intent_id AND intent.financial_command_id = NEW.financial_command_id) THEN
              RAISE EXCEPTION 'checkout attempt command must belong to its intent';
            END IF;
            IF TG_OP = 'INSERT' THEN
              SELECT COALESCE(MAX(attempt_number), 0) + 1 INTO expected_attempt_number FROM recording_studio_billing_checkout_attempts WHERE checkout_intent_id = NEW.checkout_intent_id;
              IF NEW.attempt_number IS DISTINCT FROM expected_attempt_number OR NEW.state <> 'pending' OR NEW.completed_at IS NOT NULL THEN RAISE EXCEPTION 'checkout attempts must begin sequentially and pending'; END IF;
              RETURN NEW;
            END IF;
            IF OLD.id IS DISTINCT FROM NEW.id OR OLD.checkout_intent_id IS DISTINCT FROM NEW.checkout_intent_id OR OLD.financial_command_id IS DISTINCT FROM NEW.financial_command_id OR OLD.attempt_number IS DISTINCT FROM NEW.attempt_number OR OLD.created_at IS DISTINCT FROM NEW.created_at OR OLD.completed_at IS NOT NULL THEN RAISE EXCEPTION 'checkout attempt history is immutable'; END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_checkout_attempt_history BEFORE UPDATE OR DELETE ON recording_studio_billing_checkout_attempts FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_checkout_attempt();
        SQL
      end
      direction.down do
        execute "DROP FUNCTION IF EXISTS rs_billing_validate_checkout_authority() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_validate_checkout_command_binding() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_validate_checkout_execution_state() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_protect_checkout_item() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_protect_checkout_attempt() CASCADE"
      end
    end
  end

  private

  def quoted(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end
end