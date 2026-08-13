# frozen_string_literal: true

class MakeReconciliationHistoryAppendOnly < ActiveRecord::Migration[8.1]
  def up
    remove_index :recording_studio_billing_reconciliation_records, name: "idx_rs_billing_reconciliation_command"
    add_index :recording_studio_billing_reconciliation_records, %i[financial_command_id created_at],
              name: "idx_rs_billing_reconciliation_runs"
    remove_index :recording_studio_billing_reconciliation_issues, name: "idx_rs_billing_reconciliation_issue_identity"
    add_index :recording_studio_billing_reconciliation_issues, %i[financial_command_id kind created_at],
              name: "idx_rs_billing_reconciliation_issue_history"
    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_reconciliation_history() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'reconciliation history is append-only'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_reconciliation_record_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_reconciliation_records
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_reconciliation_history();
      CREATE TRIGGER rs_billing_reconciliation_issue_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_reconciliation_issues
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_reconciliation_history();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
