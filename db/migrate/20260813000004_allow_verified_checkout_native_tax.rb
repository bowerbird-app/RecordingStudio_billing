# frozen_string_literal: true

class AllowVerifiedCheckoutNativeTax < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_studio_billing_tax_calculations, :manifest_digests, :jsonb, null: false, default: []
    execute <<~SQL
      UPDATE recording_studio_billing_tax_calculations
      SET manifest_digests = jsonb_build_array(manifest_digest)
    SQL
    add_check_constraint :recording_studio_billing_tax_calculations,
                         "jsonb_typeof(manifest_digests) = 'array' AND jsonb_array_length(manifest_digests) > 0 " \
                         "AND manifest_digests ->> 0 = manifest_digest",
                         name: "rs_billing_tax_manifest_set"
    execute <<~SQL
      CREATE OR REPLACE FUNCTION rs_billing_validate_tax_authority() RETURNS trigger AS $$
      DECLARE
        command_row recording_studio_billing_financial_commands%ROWTYPE;
        command_request jsonb;
        command_result jsonb;
        command_metadata jsonb;
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_recordings root
          WHERE root.id = NEW.root_recording_id AND root.parent_recording_id IS NULL
            AND root.root_recording_id = root.id AND root.trashed_at IS NULL
        ) THEN RAISE EXCEPTION 'tax root authority is invalid'; END IF;
        IF NOT EXISTS (
          SELECT 1 FROM recording_studio_recordings account_recording
          JOIN recording_studio_billing_accounts account ON account.id = account_recording.recordable_id
          WHERE account_recording.id = NEW.account_recording_id
            AND account_recording.recordable_type = 'RecordingStudioBilling::Account'
            AND account_recording.root_recording_id = NEW.root_recording_id
            AND account_recording.parent_recording_id = NEW.root_recording_id
            AND account_recording.trashed_at IS NULL AND account.root_recording_id = NEW.root_recording_id
        ) THEN RAISE EXCEPTION 'tax account authority is invalid'; END IF;
        SELECT * INTO command_row FROM recording_studio_billing_financial_commands
          WHERE id = NEW.financial_command_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'tax command authority is invalid'; END IF;
        command_request := command_row.canonical_request -> 'request';
        command_result := command_row.normalized_result;
        SELECT safe_metadata INTO command_metadata FROM recording_studio_billing_financial_command_attempts
          WHERE financial_command_id = NEW.financial_command_id AND completed_at IS NOT NULL
          ORDER BY attempt_number DESC LIMIT 1;

        IF command_row.command_type = 'tax_calculation' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_commercial_manifests manifest
            WHERE manifest.id = NEW.commercial_manifest_id AND manifest.root_recording_id = NEW.root_recording_id
              AND manifest.manifest_digest = NEW.manifest_digest AND manifest.used_at IS NOT NULL
          ) THEN RAISE EXCEPTION 'tax manifest authority is invalid'; END IF;
          IF command_row.root_recording_id IS DISTINCT FROM NEW.root_recording_id
             OR command_row.account_recording_id IS DISTINCT FROM NEW.account_recording_id
             OR command_row.calculator_key IS DISTINCT FROM NEW.calculator_key
             OR command_row.calculator_mode IS DISTINCT FROM NEW.calculator_mode THEN
            RAISE EXCEPTION 'tax command authority is invalid';
          END IF;
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
          IF NEW.manifest_digests IS DISTINCT FROM jsonb_build_array(NEW.manifest_digest) THEN
            RAISE EXCEPTION 'tax calculation manifest set is invalid';
          END IF;
        ELSIF command_row.command_type = 'checkout' THEN
          IF NOT EXISTS (
            SELECT 1
            FROM recording_studio_billing_commercial_manifests manifest
            JOIN recording_studio_recordings provider_recording ON provider_recording.id = command_row.provider_account_recording_id
            JOIN recording_studio_billing_provider_accounts provider ON provider.id = provider_recording.recordable_id
            JOIN recording_studio_recordings billing_admin ON billing_admin.id = provider.billing_admin_recording_id
            WHERE manifest.id = NEW.commercial_manifest_id AND manifest.manifest_digest = NEW.manifest_digest
              AND manifest.used_at IS NOT NULL AND provider_recording.recordable_type = 'RecordingStudioBilling::ProviderAccount'
              AND provider_recording.parent_recording_id = billing_admin.id
              AND manifest.root_recording_id = billing_admin.root_recording_id
              AND provider.adapter_key = command_row.provider_adapter_key
              AND manifest.recording_snapshots @> jsonb_build_array(jsonb_build_object('recording_id', provider_recording.id))
          ) THEN RAISE EXCEPTION 'native checkout tax manifest authority is invalid'; END IF;
          IF NEW.manifest_digests IS DISTINCT FROM command_row.canonical_request -> 'authority' -> 'commercial_manifest_digests'
             OR NEW.manifest_digest IS DISTINCT FROM NEW.manifest_digests ->> 0
             OR EXISTS (
               SELECT 1 FROM jsonb_array_elements_text(NEW.manifest_digests) digest
               WHERE NOT EXISTS (
                 SELECT 1
                 FROM recording_studio_billing_commercial_manifests manifest
                 JOIN recording_studio_recordings provider_recording ON provider_recording.id = command_row.provider_account_recording_id
                 WHERE manifest.root_recording_id = provider_recording.root_recording_id
                   AND manifest.manifest_digest = digest.value AND manifest.used_at IS NOT NULL
                   AND manifest.recording_snapshots @> jsonb_build_array(jsonb_build_object('recording_id', provider_recording.id))
               )
             ) THEN RAISE EXCEPTION 'native checkout tax manifest set authority is invalid'; END IF;
          IF command_row.state <> 'succeeded'
             OR command_row.root_recording_id IS DISTINCT FROM NEW.root_recording_id
             OR command_row.account_recording_id IS DISTINCT FROM NEW.account_recording_id
             OR command_request #>> '{tax,enabled}' IS DISTINCT FROM 'true'
             OR command_request #>> '{tax,mode}' IS DISTINCT FROM 'provider_native'
             OR command_request #>> '{tax,calculator_key}' IS DISTINCT FROM NEW.calculator_key
             OR NEW.calculator_mode <> 'provider_calculation'
             OR command_request #>> '{tax,behavior}' IS DISTINCT FROM NEW.behavior
             OR jsonb_typeof(command_request #> '{tax,semantic_categories}') IS DISTINCT FROM 'array'
             OR jsonb_typeof(command_request #> '{tax,location_requirements}') IS DISTINCT FROM 'array'
             OR NOT (command_row.canonical_request -> 'authority' -> 'commercial_manifest_digests' ? NEW.manifest_digest)
             OR NEW.revision_number <> 1 OR NEW.supersedes_id IS NOT NULL
             OR NEW.status <> 'success'
             OR command_result ->> 'authority' IS DISTINCT FROM 'verified_webhook'
             OR command_result ->> 'payment_state' IS DISTINCT FROM 'paid'
             OR jsonb_typeof(command_result -> 'lines') IS DISTINCT FROM 'array'
             OR jsonb_array_length(command_result -> 'lines') = 0
             OR NOT EXISTS (
               SELECT 1 FROM jsonb_array_elements(command_result -> 'lines') AS line
               WHERE line ->> 'manifest_digest' = NEW.manifest_digest
             )
             OR NEW.operation_reference IS DISTINCT FROM command_row.operation_id::text
             OR NEW.idempotency_key IS DISTINCT FROM command_row.provider_idempotency_key
             OR NEW.request_fingerprint IS DISTINCT FROM command_row.request_fingerprint
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
            RAISE EXCEPTION 'native checkout tax does not match the verified provider result';
          END IF;
          IF (SELECT count(*) FROM jsonb_array_elements(command_result -> 'lines')) IS DISTINCT FROM (
               SELECT count(*) FROM recording_studio_billing_checkout_intent_items item
               WHERE item.checkout_intent_id = (command_request ->> 'checkout_intent_id')::uuid
             )
             OR EXISTS (
               SELECT 1
               FROM recording_studio_billing_checkout_intent_items item
               WHERE item.checkout_intent_id = (command_request ->> 'checkout_intent_id')::uuid
                 AND NOT EXISTS (
                   SELECT 1 FROM jsonb_array_elements(command_result -> 'lines') line
                   WHERE line ->> 'checkout_intent_item_id' = item.id::text
                     AND line ->> 'manifest_digest' = item.manifest_digest
                     AND line ->> 'currency' = item.currency_code
                     AND (line ->> 'quantity')::integer IS NOT DISTINCT FROM item.quantity
                     AND (line ->> 'unit_amount_minor')::bigint IS NOT DISTINCT FROM
                         (item.commercial_manifest #>> '{canonical_data,price,amount_minor}')::bigint
                     AND (line ->> 'subtotal_minor')::bigint IS NOT DISTINCT FROM
                         (item.commercial_manifest #>> '{canonical_data,price,amount_minor}')::bigint * item.quantity
                     AND (line ->> 'discount_minor')::bigint IS NOT DISTINCT FROM
                         COALESCE((item.commercial_manifest #>> '{canonical_data,discount_policy,amount_minor}')::bigint, 0)
                     AND (line ->> 'total_minor')::bigint IS NOT DISTINCT FROM
                         (line ->> 'subtotal_minor')::bigint - (line ->> 'discount_minor')::bigint +
                           (line ->> 'tax_minor')::bigint
                 )
             ) THEN RAISE EXCEPTION 'native checkout tax lines do not match frozen checkout items'; END IF;
        ELSE
          RAISE EXCEPTION 'tax command authority is invalid';
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
        ) THEN RAISE EXCEPTION 'tax calculation revision history is invalid'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
