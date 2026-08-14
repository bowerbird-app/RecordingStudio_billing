# frozen_string_literal: true

class RepairTaxCalculationManifestSets < ActiveRecord::Migration[8.1]
  TABLE = :recording_studio_billing_tax_calculations
  CONSTRAINT = "rs_billing_tax_manifest_set"
  FUNCTION = "rs_billing_validate_tax_manifest_set"
  TRIGGER = "rs_billing_tax_manifest_set_authority"

  def up
    add_column TABLE, :manifest_digests, :jsonb, null: false, default: [] unless column_exists?(TABLE, :manifest_digests)
    execute <<~SQL
      UPDATE #{TABLE}
      SET manifest_digests = jsonb_build_array(manifest_digest)
      WHERE manifest_digests IS NULL OR manifest_digests = '[]'::jsonb
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION rs_billing_sorted_manifest_set(digests jsonb, anchor text) RETURNS boolean AS $$
      DECLARE
        digest text;
        previous_digest text;
      BEGIN
        IF jsonb_typeof(digests) <> 'array'
           OR jsonb_array_length(digests) = 0
           OR digests ->> 0 <> anchor THEN
          RETURN false;
        END IF;

        FOR digest IN SELECT jsonb_array_elements_text(digests)
        LOOP
          IF digest !~ '^[0-9a-f]{64}$'
             OR (previous_digest IS NOT NULL AND digest <= previous_digest) THEN
            RETURN false;
          END IF;
          previous_digest := digest;
        END LOOP;

        RETURN true;
      END;
      $$ LANGUAGE plpgsql IMMUTABLE;

      CREATE OR REPLACE FUNCTION #{FUNCTION}() RETURNS trigger AS $$
      DECLARE
        command_row recording_studio_billing_financial_commands%ROWTYPE;
      BEGIN
        IF NOT rs_billing_sorted_manifest_set(NEW.manifest_digests, NEW.manifest_digest) THEN
          RAISE EXCEPTION 'tax calculation manifest set is invalid';
        END IF;

        SELECT * INTO command_row
        FROM recording_studio_billing_financial_commands
        WHERE id = NEW.financial_command_id;

        IF command_row.command_type = 'tax_calculation'
           AND NEW.manifest_digests IS DISTINCT FROM jsonb_build_array(NEW.manifest_digest) THEN
          RAISE EXCEPTION 'tax calculation manifest set is invalid';
        END IF;

        IF command_row.command_type = 'checkout'
           AND NEW.manifest_digests IS DISTINCT FROM command_row.canonical_request -> 'authority' -> 'commercial_manifest_digests' THEN
          RAISE EXCEPTION 'native checkout tax manifest set authority is invalid';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS #{TRIGGER} ON #{TABLE};
      CREATE TRIGGER #{TRIGGER}
      BEFORE INSERT ON #{TABLE}
      FOR EACH ROW EXECUTE FUNCTION #{FUNCTION}();
    SQL

    remove_check_constraint TABLE, name: CONSTRAINT if check_constraint_exists?(TABLE, name: CONSTRAINT)
    add_check_constraint TABLE,
                         "rs_billing_sorted_manifest_set(manifest_digests, manifest_digest)",
                         name: CONSTRAINT
  end

  def down
    remove_check_constraint TABLE, name: CONSTRAINT
    execute "DROP TRIGGER IF EXISTS #{TRIGGER} ON #{TABLE}"
    execute "DROP FUNCTION IF EXISTS #{FUNCTION}()"
    execute "DROP FUNCTION IF EXISTS rs_billing_sorted_manifest_set(jsonb, text)"
  end
end
