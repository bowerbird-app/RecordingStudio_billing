# frozen_string_literal: true

class CreateTaxCalculations < ActiveRecord::Migration[8.1]
  STATUSES = %w[
    success duplicate invalid unauthorized unsupported unsupported_tax_calculation
    unsupported_checkout_mode unsupported_checkout_composition unsupported_subscription_composition
    unsupported_market unsupported_currency charge_market_verification_unavailable conflict
    provider_unavailable provider_rejected pending stale rate_missing rate_ambiguous
    requires_review failed unknown
  ].freeze

  def change
    create_table :recording_studio_billing_tax_calculations, id: :uuid do |t|
      t.references :financial_command, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.references :root_recording, null: false, type: :uuid,
                                    foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_recordings }
      t.references :commercial_manifest, null: false, type: :uuid,
                                         foreign_key: { to_table: :recording_studio_billing_commercial_manifests }
      t.references :supersedes, type: :uuid,
                foreign_key: { to_table: :recording_studio_billing_tax_calculations }
      t.integer :revision_number, null: false, default: 1
      t.string :calculator_key, null: false
      t.string :calculator_mode, null: false
      t.string :manifest_digest, null: false
      t.string :transaction_type, null: false
      t.string :operation_reference, null: false
      t.string :request_fingerprint, null: false
      t.string :idempotency_key, null: false
      t.bigint :subtotal_minor, null: false
      t.bigint :discount_minor, null: false
      t.bigint :tax_minor, null: false
      t.bigint :total_minor, null: false
      t.string :currency, null: false
      t.string :behavior, null: false
      t.string :status, null: false
      t.jsonb :breakdown, null: false, default: []
      t.string :calculator_reference, null: false
      t.datetime :calculated_at, null: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :recording_studio_billing_tax_calculations, %i[financial_command_id revision_number], unique: true,
          name: "idx_rs_billing_tax_command_revision"
    add_index :recording_studio_billing_tax_calculations,
          %i[root_recording_id idempotency_key revision_number], unique: true,
              name: "idx_rs_billing_tax_idempotency"
    add_index :recording_studio_billing_tax_calculations, :request_fingerprint,
              name: "idx_rs_billing_tax_fingerprint"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "calculator_key ~ '^[a-z][a-z0-9_]*$'", name: "rs_billing_tax_calculator_key"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "calculator_mode IN ('external_calculation', 'provider_calculation')",
                         name: "rs_billing_tax_calculator_mode"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "manifest_digest ~ '^[0-9a-f]{64}$' AND request_fingerprint ~ '^[0-9a-f]{64}$'",
                         name: "rs_billing_tax_digests"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "currency ~ '^[A-Z]{3}$'", name: "rs_billing_tax_currency"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "behavior IN ('inclusive', 'exclusive', 'provider_default')",
                         name: "rs_billing_tax_behavior"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "status IN (#{quoted(STATUSES)})", name: "rs_billing_tax_status"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "subtotal_minor >= 0 AND discount_minor >= 0 AND tax_minor >= 0 AND total_minor >= 0",
                         name: "rs_billing_tax_nonnegative"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "discount_minor <= subtotal_minor", name: "rs_billing_tax_discount"
    add_check_constraint :recording_studio_billing_tax_calculations,
               "revision_number > 0 AND ((revision_number = 1) = (supersedes_id IS NULL))",
               name: "rs_billing_tax_revision"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "(behavior = 'exclusive' AND total_minor = subtotal_minor - discount_minor + tax_minor) OR " \
                         "(behavior IN ('inclusive', 'provider_default') AND total_minor = subtotal_minor - discount_minor " \
                         "AND tax_minor <= total_minor)", name: "rs_billing_tax_arithmetic"
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "jsonb_typeof(breakdown) = 'array' AND jsonb_typeof(safe_metadata) = 'object'",
                         name: "rs_billing_tax_safe_json"

    reversible do |direction|
      direction.up do
        protect_tax_history
        validate_tax_authority
      end
      direction.down do
        execute "DROP FUNCTION IF EXISTS rs_billing_protect_tax_calculation() CASCADE"
        execute "DROP FUNCTION IF EXISTS rs_billing_validate_tax_authority() CASCADE"
      end
    end
  end

  private

  def protect_tax_history
    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_tax_calculation() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'tax calculations are immutable and append-only';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER rs_billing_tax_calculation_history
      BEFORE UPDATE OR DELETE ON recording_studio_billing_tax_calculations
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_tax_calculation();
    SQL
  end

  def validate_tax_authority
    execute <<~SQL
      CREATE FUNCTION rs_billing_validate_tax_authority() RETURNS trigger AS $$
      DECLARE command_request jsonb;
      DECLARE command_result jsonb;
      DECLARE command_metadata jsonb;
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_recordings root
          WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL
            AND root.root_recording_id = root.id AND root.trashed_at IS NULL
        ) THEN
          RAISE EXCEPTION 'tax root authority is invalid';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_recordings account_recording
          JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
          WHERE account_recording.id = NEW.account_recording_id
            AND account_recording.recordable_type = 'RecordingStudioBilling::Account'
            AND account_recording.root_recording_id = NEW.root_recording_id
            AND account_recording.parent_recording_id = NEW.root_recording_id
            AND account_recording.trashed_at IS NULL AND account.root_recording_id = NEW.root_recording_id
        ) THEN
          RAISE EXCEPTION 'tax account authority is invalid';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_commercial_manifests manifest
          WHERE manifest.id = NEW.commercial_manifest_id AND manifest.root_recording_id = NEW.root_recording_id
            AND manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL
        ) THEN
          RAISE EXCEPTION 'tax manifest authority is invalid';
        END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_financial_commands command
          WHERE command.id = NEW.financial_command_id AND command.command_type = 'tax_calculation'
            AND command.root_recording_id = NEW.root_recording_id
            AND command.account_recording_id = NEW.account_recording_id
            AND command.calculator_key = NEW.calculator_key
            AND command.calculator_mode = NEW.calculator_mode
        ) THEN
          RAISE EXCEPTION 'tax command authority is invalid';
        END IF;
        SELECT canonical_request -> 'request', normalized_result
          INTO command_request, command_result
        FROM recording_studio_billing_financial_commands WHERE id = NEW.financial_command_id;
        SELECT safe_metadata INTO command_metadata
        FROM recording_studio_billing_financial_command_attempts
        WHERE financial_command_id = NEW.financial_command_id AND completed_at IS NOT NULL
        ORDER BY attempt_number DESC LIMIT 1;
        IF command_request ->> 'commercial_manifest_id' IS DISTINCT FROM NEW.commercial_manifest_id::text
           OR command_request ->> 'commercial_manifest_digest' IS DISTINCT FROM NEW.manifest_digest
           OR command_request ->> 'transaction_type' IS DISTINCT FROM NEW.transaction_type
           OR command_request ->> 'operation_reference' IS DISTINCT FROM NEW.operation_reference
           OR command_request ->> 'idempotency_key' IS DISTINCT FROM NEW.idempotency_key
           OR (command_request ->> 'subtotal_minor')::bigint IS DISTINCT FROM NEW.subtotal_minor
           OR (command_request ->> 'discount_minor')::bigint IS DISTINCT FROM NEW.discount_minor
           OR command_request ->> 'currency' IS DISTINCT FROM NEW.currency
           OR command_result ->> 'request_fingerprint' IS DISTINCT FROM NEW.request_fingerprint
           OR command_result ->> 'status' IS DISTINCT FROM NEW.status
           OR (command_result ->> 'subtotal_minor')::bigint IS DISTINCT FROM NEW.subtotal_minor
           OR (command_result ->> 'discount_minor')::bigint IS DISTINCT FROM NEW.discount_minor
           OR (command_result ->> 'tax_minor')::bigint IS DISTINCT FROM NEW.tax_minor
           OR (command_result ->> 'total_minor')::bigint IS DISTINCT FROM NEW.total_minor
           OR command_result ->> 'currency' IS DISTINCT FROM NEW.currency
            OR command_result ->> 'behavior' IS DISTINCT FROM NEW.behavior
            OR command_result -> 'breakdown' IS DISTINCT FROM NEW.breakdown
            OR command_result ->> 'calculator_reference' IS DISTINCT FROM NEW.calculator_reference
            OR (command_result ->> 'calculated_at')::timestamptz IS DISTINCT FROM NEW.calculated_at
            OR command_metadata IS DISTINCT FROM NEW.safe_metadata THEN
          RAISE EXCEPTION 'tax calculation does not match its durable command';
        END IF;
          IF NOT rs_billing_safe_financial_json(NEW.breakdown)
            OR NOT rs_billing_safe_financial_json(NEW.safe_metadata)
            OR NEW.operation_reference ~* '^[[:space:]]*(https?|ftp)://'
            OR NEW.calculator_reference ~* '^[[:space:]]*(https?|ftp)://' THEN
           RAISE EXCEPTION 'tax calculation contains unsafe persisted data';
          END IF;
        IF NEW.revision_number > 1 AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_tax_calculations previous
          WHERE previous.id = NEW.supersedes_id
            AND previous.financial_command_id = NEW.financial_command_id
            AND previous.revision_number = NEW.revision_number - 1
            AND previous.root_recording_id = NEW.root_recording_id
            AND previous.idempotency_key = NEW.idempotency_key
            AND previous.calculator_key = NEW.calculator_key
            AND previous.calculator_mode = NEW.calculator_mode
            AND previous.request_fingerprint = NEW.request_fingerprint
        ) THEN
          RAISE EXCEPTION 'tax calculation revision history is invalid';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER rs_billing_tax_calculation_authority
      BEFORE INSERT ON recording_studio_billing_tax_calculations
      FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_tax_authority();
    SQL
  end

  def quoted(values)
    values.map { |value| connection.quote(value) }.join(", ")
  end
end