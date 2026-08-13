# frozen_string_literal: true

class CreateFinancialCommands < ActiveRecord::Migration[8.1]
  COMMAND_STATES = %w[pending processing succeeded failed uncertain requires_reconciliation cancelled].freeze
  RECONCILIATION_STATES = %w[not_required pending processing reconciled failed].freeze

  def change
    create_table :recording_studio_billing_financial_commands, id: :uuid do |t|
      t.uuid :operation_id, null: false, default: -> { "gen_random_uuid()" }
      t.string :command_type, null: false
      t.references :root_recording, null: false, type: :uuid,
                                    foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_recordings }
      t.references :provider_account_recording, type: :uuid,
                                                foreign_key: { to_table: :recording_studio_recordings }
      t.string :provider_adapter_key
      t.string :calculator_key
      t.string :calculator_mode
      t.jsonb :canonical_request, null: false
      t.string :request_fingerprint, null: false
      t.string :local_idempotency_key, null: false
      t.string :provider_idempotency_key, null: false
      t.string :state, null: false, default: "pending"
      t.string :provider_reference
      t.jsonb :normalized_result, null: false, default: {}
      t.jsonb :safe_error_details, null: false, default: {}
      t.string :reconciliation_state, null: false, default: "not_required"
      t.uuid :claim_token
      t.datetime :claimed_at
      t.datetime :lease_expires_at
      t.timestamps
    end

    add_index :recording_studio_billing_financial_commands, :operation_id, unique: true,
                                                                           name: "idx_rs_billing_commands_operation"
    add_index :recording_studio_billing_financial_commands,
              %i[root_recording_id local_idempotency_key], unique: true,
                                                           name: "idx_rs_billing_commands_local_idempotency"
    add_index :recording_studio_billing_financial_commands, :provider_idempotency_key, unique: true,
                                                                                       name: "idx_rs_billing_commands_provider_idempotency"
    add_index :recording_studio_billing_financial_commands, :created_at,
              where: "state = 'pending'", name: "idx_rs_billing_commands_pending_work"
    add_index :recording_studio_billing_financial_commands, :lease_expires_at,
              where: "state = 'processing'", name: "idx_rs_billing_commands_stale_processing"
    add_index :recording_studio_billing_financial_commands, :updated_at,
              where: "state = 'requires_reconciliation' OR reconciliation_state = 'pending'",
              name: "idx_rs_billing_commands_reconciliation_work"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "state IN (#{quoted(COMMAND_STATES)})", name: "rs_billing_commands_state"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "reconciliation_state IN (#{quoted(RECONCILIATION_STATES)})",
                         name: "rs_billing_commands_reconciliation_state"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "command_type ~ '^[a-z][a-z0-9_]*$'", name: "rs_billing_commands_type_format"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "request_fingerprint ~ '^[0-9a-f]{64}$'", name: "rs_billing_commands_fingerprint"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "jsonb_typeof(canonical_request) = 'object'", name: "rs_billing_commands_request_object"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "jsonb_typeof(normalized_result) = 'object'", name: "rs_billing_commands_result_object"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "jsonb_typeof(safe_error_details) = 'object'", name: "rs_billing_commands_error_object"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "((provider_account_recording_id IS NOT NULL AND provider_adapter_key IS NOT NULL " \
                         "AND calculator_key IS NULL AND calculator_mode IS NULL) OR " \
                         "(provider_account_recording_id IS NULL AND provider_adapter_key IS NULL " \
                         "AND calculator_key IS NOT NULL AND calculator_mode IS NOT NULL))",
                         name: "rs_billing_commands_one_executor"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "provider_adapter_key IS NULL OR provider_adapter_key ~ '^[a-z][a-z0-9_]*$'",
                         name: "rs_billing_commands_provider_adapter_key"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "calculator_key IS NULL OR calculator_key ~ '^[a-z][a-z0-9_]*$'",
                         name: "rs_billing_commands_calculator_key"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "calculator_mode IS NULL OR calculator_mode IN ('external_calculation', 'provider_calculation')",
                         name: "rs_billing_commands_calculator_mode"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "(claim_token IS NULL AND claimed_at IS NULL AND lease_expires_at IS NULL) OR " \
                         "(claim_token IS NOT NULL AND claimed_at IS NOT NULL AND lease_expires_at > claimed_at)",
                         name: "rs_billing_commands_complete_claim"
    add_check_constraint :recording_studio_billing_financial_commands,
                         "(state = 'processing') = (claim_token IS NOT NULL)",
                         name: "rs_billing_commands_processing_claimed"

    create_table :recording_studio_billing_financial_command_attempts, id: :uuid do |t|
      t.references :financial_command, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.integer :attempt_number, null: false
      t.string :state, null: false
      t.string :provider_idempotency_key, null: false
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.jsonb :normalized_result, null: false, default: {}
      t.jsonb :safe_error_details, null: false, default: {}
      t.boolean :uncertain_outcome, null: false, default: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :recording_studio_billing_financial_command_attempts,
              %i[financial_command_id attempt_number], unique: true,
                                                       name: "idx_rs_billing_command_attempt_number"
    add_index :recording_studio_billing_financial_command_attempts, :financial_command_id,
              unique: true, where: "state = 'processing' AND completed_at IS NULL",
              name: "idx_rs_billing_one_processing_attempt"
    add_check_constraint :recording_studio_billing_financial_command_attempts,
                         "attempt_number > 0", name: "rs_billing_command_attempts_positive_number"
    add_check_constraint :recording_studio_billing_financial_command_attempts,
                         "state IN (#{quoted(COMMAND_STATES)})", name: "rs_billing_command_attempts_state"
    add_check_constraint :recording_studio_billing_financial_command_attempts,
                         "completed_at IS NULL OR completed_at >= started_at",
                         name: "rs_billing_command_attempts_times"
    add_check_constraint :recording_studio_billing_financial_command_attempts,
                         "(state = 'processing' AND completed_at IS NULL) OR " \
                         "(state IN ('succeeded', 'failed', 'uncertain', 'requires_reconciliation', 'cancelled') " \
                         "AND completed_at IS NOT NULL)",
                         name: "rs_billing_command_attempts_lifecycle"
    %w[normalized_result safe_error_details safe_metadata].each do |column|
      add_check_constraint :recording_studio_billing_financial_command_attempts,
                           "jsonb_typeof(#{column}) = 'object'",
                           name: "rs_billing_command_attempts_#{column}_object"
    end

    reversible do |direction|
      direction.up do
        create_safe_payload_function
        validate_command_authority
        protect_command_history
        protect_attempt_history
        enforce_command_attempt_consistency
      end
      direction.down do
        execute "DROP FUNCTION IF EXISTS rs_billing_protect_command_attempt() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_protect_financial_command() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_validate_command_authority() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_validate_command_attempt_consistency() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_safe_financial_json(jsonb) CASCADE"
      end
    end
  end

  private

  def create_safe_payload_function
    execute <<~SQL
      CREATE FUNCTION rs_billing_safe_financial_json(payload jsonb) RETURNS boolean AS $$
        SELECT NOT jsonb_path_exists(
          payload,
          '$.**.keyvalue() ? (@.key like_regex "(authorization|credential|password|secret|token|api[_-]?key|private[_-]?key|signature|card[_-]?(number|cvc|cvv)|payment[_-]?(nonce|credential)|bank[_-]?account|routing[_-]?number|provider[_-]?(url|uri|id|identifier|account[_-]?id|customer[_-]?id|response|payload|body)|raw[_-]?(provider|response|payload|body)|(^|[_-])(tax|vat)[_-]?(id|identifier|number)|(^|[_-])(email|phone|address|postal[_-]?code|ip[_-]?address)|(^|[_-])(url|uri)$)" flag "i")'
        ) AND NOT jsonb_path_exists(
          payload,
          '$.** ? (@.type() == "string" && @ like_regex "^[[:space:]]*(https?|ftp)://" flag "i")'
        );
      $$ LANGUAGE sql IMMUTABLE;
    SQL
  end

  def validate_command_authority
    execute <<~SQL
      CREATE FUNCTION rs_billing_validate_command_authority() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'UPDATE' AND NOT (NEW.state = 'processing' AND OLD.state IS DISTINCT FROM NEW.state) THEN
          RETURN NEW;
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_recordings root
          WHERE root.id = NEW.root_recording_id
            AND root.parent_recording_id IS NULL
            AND root.root_recording_id = root.id
            AND root.trashed_at IS NULL
        ) THEN
          RAISE EXCEPTION 'financial command root authority is invalid';
        END IF;
        IF NOT EXISTS (
          SELECT 1
          FROM recording_studio_recordings account_recording
          JOIN recording_studio_billing_accounts account
            ON account.id = account_recording.recordable_id
          WHERE account_recording.id = NEW.account_recording_id
            AND account_recording.recordable_type = 'RecordingStudioBilling::Account'
            AND account_recording.root_recording_id = NEW.root_recording_id
            AND account_recording.parent_recording_id = NEW.root_recording_id
            AND account_recording.trashed_at IS NULL
            AND account.root_recording_id = NEW.root_recording_id
        ) THEN
          RAISE EXCEPTION 'financial command account authority is invalid';
        END IF;
        IF NEW.provider_account_recording_id IS NOT NULL AND NOT EXISTS (
          SELECT 1
          FROM recording_studio_recordings provider_recording
          JOIN recording_studio_billing_provider_accounts provider
            ON provider.id = provider_recording.recordable_id
          JOIN recording_studio_recordings admin_recording
            ON admin_recording.id = provider.billing_admin_recording_id
          JOIN recording_studio_billing_billing_admins admin
            ON admin.id = admin_recording.recordable_id
          WHERE provider_recording.id = NEW.provider_account_recording_id
            AND provider_recording.recordable_type = 'RecordingStudioBilling::ProviderAccount'
            AND provider_recording.parent_recording_id = admin_recording.id
            AND provider_recording.root_recording_id = admin_recording.root_recording_id
            AND provider_recording.trashed_at IS NULL
            AND provider.adapter_key = NEW.provider_adapter_key
            AND admin_recording.recordable_type = 'RecordingStudioBilling::BillingAdmin'
            AND admin_recording.trashed_at IS NULL
            AND admin.root_recording_id = admin_recording.root_recording_id
        ) THEN
          RAISE EXCEPTION 'financial command provider authority is invalid';
        END IF;
        IF NOT rs_billing_safe_financial_json(NEW.canonical_request -> 'request')
           OR NOT rs_billing_safe_financial_json(NEW.normalized_result)
           OR NOT rs_billing_safe_financial_json(NEW.safe_error_details)
           OR NEW.provider_reference ~* '^[[:space:]]*(https?|ftp)://' THEN
          RAISE EXCEPTION 'financial command contains unsafe persisted data';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER rs_billing_financial_command_authority
      BEFORE INSERT OR UPDATE
      ON recording_studio_billing_financial_commands
      FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_command_authority();
    SQL
  end

  def protect_command_history
    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_financial_command() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'financial commands are durable';
        END IF;
        IF OLD.operation_id IS DISTINCT FROM NEW.operation_id
           OR OLD.command_type IS DISTINCT FROM NEW.command_type
           OR OLD.root_recording_id IS DISTINCT FROM NEW.root_recording_id
           OR OLD.account_recording_id IS DISTINCT FROM NEW.account_recording_id
           OR OLD.provider_account_recording_id IS DISTINCT FROM NEW.provider_account_recording_id
           OR OLD.provider_adapter_key IS DISTINCT FROM NEW.provider_adapter_key
           OR OLD.calculator_key IS DISTINCT FROM NEW.calculator_key
           OR OLD.calculator_mode IS DISTINCT FROM NEW.calculator_mode
           OR OLD.canonical_request IS DISTINCT FROM NEW.canonical_request
           OR OLD.request_fingerprint IS DISTINCT FROM NEW.request_fingerprint
           OR OLD.local_idempotency_key IS DISTINCT FROM NEW.local_idempotency_key
           OR OLD.provider_idempotency_key IS DISTINCT FROM NEW.provider_idempotency_key THEN
          RAISE EXCEPTION 'financial command authority is immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER rs_billing_financial_command_history
      BEFORE UPDATE OR DELETE ON recording_studio_billing_financial_commands
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_financial_command();
    SQL
  end

  def protect_attempt_history
    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_command_attempt() RETURNS trigger AS $$
      DECLARE command_idempotency_key text;
      DECLARE expected_attempt_number integer;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'financial command attempts are append-only';
        END IF;
        SELECT provider_idempotency_key INTO command_idempotency_key
        FROM recording_studio_billing_financial_commands
        WHERE id = NEW.financial_command_id;
        IF NEW.provider_idempotency_key IS DISTINCT FROM command_idempotency_key THEN
          RAISE EXCEPTION 'attempt idempotency key must match its financial command';
        END IF;
        IF NOT rs_billing_safe_financial_json(NEW.normalized_result)
           OR NOT rs_billing_safe_financial_json(NEW.safe_error_details)
           OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN
          RAISE EXCEPTION 'financial command attempt contains unsafe persisted data';
        END IF;
        IF TG_OP = 'INSERT' THEN
          IF NEW.state <> 'processing' OR NEW.completed_at IS NOT NULL THEN
            RAISE EXCEPTION 'financial command attempts must begin processing and incomplete';
          END IF;
          SELECT COALESCE(MAX(attempt_number), 0) + 1 INTO expected_attempt_number
          FROM recording_studio_billing_financial_command_attempts
          WHERE financial_command_id = NEW.financial_command_id;
          IF NEW.attempt_number IS DISTINCT FROM expected_attempt_number THEN
            RAISE EXCEPTION 'financial command attempts must be sequential';
          END IF;
          RETURN NEW;
        END IF;
        IF OLD.id IS DISTINCT FROM NEW.id
           OR OLD.created_at IS DISTINCT FROM NEW.created_at
           OR OLD.financial_command_id IS DISTINCT FROM NEW.financial_command_id
           OR OLD.attempt_number IS DISTINCT FROM NEW.attempt_number
           OR OLD.provider_idempotency_key IS DISTINCT FROM NEW.provider_idempotency_key
           OR OLD.started_at IS DISTINCT FROM NEW.started_at
           OR OLD.completed_at IS NOT NULL
           OR NEW.completed_at IS NULL
           OR NEW.state NOT IN ('succeeded', 'failed', 'uncertain', 'requires_reconciliation', 'cancelled') THEN
          RAISE EXCEPTION 'financial command attempt history is immutable';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER rs_billing_command_attempt_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_financial_command_attempts
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_command_attempt();
    SQL
  end

  def enforce_command_attempt_consistency
    execute <<~SQL
      CREATE FUNCTION rs_billing_validate_command_attempt_consistency() RETURNS trigger AS $$
      DECLARE command_uuid uuid;
      DECLARE command_state text;
      DECLARE open_attempts integer;
      DECLARE trigger_row jsonb;
      BEGIN
        trigger_row := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
        command_uuid := (trigger_row ->> CASE
          WHEN TG_TABLE_NAME = 'recording_studio_billing_financial_commands' THEN 'id'
          ELSE 'financial_command_id'
        END)::uuid;
        SELECT state INTO command_state
        FROM recording_studio_billing_financial_commands
        WHERE id = command_uuid;
        IF command_state IS NULL THEN
          RETURN NULL;
        END IF;
        SELECT COUNT(*) INTO open_attempts
        FROM recording_studio_billing_financial_command_attempts
        WHERE financial_command_id = command_uuid
          AND state = 'processing' AND completed_at IS NULL;
        IF (command_state = 'processing' AND open_attempts <> 1)
           OR (command_state <> 'processing' AND open_attempts <> 0) THEN
          RAISE EXCEPTION 'financial command and attempt lifecycle is inconsistent';
        END IF;
        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql;

      CREATE CONSTRAINT TRIGGER rs_billing_command_attempt_consistency_from_command
      AFTER INSERT OR UPDATE ON recording_studio_billing_financial_commands
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_command_attempt_consistency();

      CREATE CONSTRAINT TRIGGER rs_billing_command_attempt_consistency_from_attempt
      AFTER INSERT OR UPDATE OR DELETE ON recording_studio_billing_financial_command_attempts
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_command_attempt_consistency();
    SQL
  end

  def quoted(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end
end
