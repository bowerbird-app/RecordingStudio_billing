# frozen_string_literal: true

class MakeUsageGrantsAppendOnly < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_studio_billing_usage_credit_grants, :grant_kind, :string, null: false, default: "credit"
    add_check_constraint :recording_studio_billing_usage_credit_grants,
                         "grant_kind IN ('allowance', 'credit')", name: "rs_billing_usage_grant_kind"

    remove_check_constraint :recording_studio_billing_usage_ledger_entries,
                            name: "rs_billing_usage_ledger_entry_shape"
    add_check_constraint :recording_studio_billing_usage_ledger_entries,
                         "entry_kind IN ('grant', 'consume', 'expire', 'reverse', 'adjustment', 'overage') AND quantity >= 0 AND sequence > 0",
                         name: "rs_billing_usage_ledger_entry_shape"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION rs_billing_protect_usage_credit_grant() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'usage credit grants are append-only'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_usage_credit_grant_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_usage_credit_grants
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_usage_credit_grant();
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS rs_billing_protect_usage_credit_grant() CASCADE"
    remove_check_constraint :recording_studio_billing_usage_ledger_entries,
                            name: "rs_billing_usage_ledger_entry_shape"
    add_check_constraint :recording_studio_billing_usage_ledger_entries,
                         "entry_kind IN ('grant', 'allocation', 'overage', 'correction', 'reversal') AND quantity >= 0 AND sequence > 0",
                         name: "rs_billing_usage_ledger_entry_shape"
    remove_check_constraint :recording_studio_billing_usage_credit_grants, name: "rs_billing_usage_grant_kind"
    remove_column :recording_studio_billing_usage_credit_grants, :grant_kind
  end
end
