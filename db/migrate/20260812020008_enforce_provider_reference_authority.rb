# frozen_string_literal: true

class EnforceProviderReferenceAuthority < ActiveRecord::Migration[8.1]
  def up
    add_check_constraint :recording_studio_billing_provider_references,
                         "remote_type ~ '^[a-zA-Z0-9_.:-]+$' AND remote_id ~ '^[a-zA-Z0-9_.:-]+$'",
                         name: "rs_billing_provider_reference_safe_remote_identity"
    execute <<~SQL
      CREATE FUNCTION rs_billing_validate_provider_reference() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'provider references are append-only'; END IF;
        IF NOT EXISTS (
          SELECT 1
          FROM recording_studio_recordings provider_recording
          JOIN recording_studio_billing_provider_accounts provider ON provider.id = provider_recording.recordable_id
          JOIN recording_studio_billing_financial_commands command ON command.id = NEW.financial_command_id
          WHERE provider_recording.id = NEW.provider_account_recording_id
            AND provider_recording.recordable_type = 'RecordingStudioBilling::ProviderAccount'
            AND command.provider_account_recording_id = NEW.provider_account_recording_id
            AND command.provider_adapter_key = NEW.provider_adapter_key
            AND provider.adapter_key = NEW.provider_adapter_key
            AND provider.environment = NEW.environment
        ) THEN RAISE EXCEPTION 'provider reference authority is invalid'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_provider_reference_authority
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_provider_references
      FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_provider_reference();
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS rs_billing_validate_provider_reference() CASCADE"
    remove_check_constraint :recording_studio_billing_provider_references,
                            name: "rs_billing_provider_reference_safe_remote_identity"
  end
end
