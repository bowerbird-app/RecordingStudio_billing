# frozen_string_literal: true

class HardenUsageLifecycleControls < ActiveRecord::Migration[8.1]
  def change
    add_reference :recording_studio_billing_usage_allocations, :usage_period, type: :uuid,
                                                                              foreign_key: { to_table: :recording_studio_billing_usage_periods }

    create_table :recording_studio_billing_usage_allowance_policies, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :usage_period, null: false, type: :uuid,
                                  foreign_key: { to_table: :recording_studio_billing_usage_periods }
      t.string :usage_key, null: false
      t.string :policy_kind, null: false, default: "hard_cap"
      t.bigint :limit_quantity, null: false
      t.bigint :consumed_quantity, null: false, default: 0
      t.datetime :effective_at, null: false
      t.datetime :expires_at
      t.datetime :revoked_at
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_usage_allowance_policies,
              %i[usage_period_id usage_key effective_at], unique: true,
                                                          name: "idx_rs_billing_usage_allowance_policy"
    add_check_constraint :recording_studio_billing_usage_allowance_policies,
                         "policy_kind IN ('hard_cap', 'soft_cap') AND limit_quantity >= 0 AND consumed_quantity >= 0 AND consumed_quantity <= limit_quantity",
                         name: "rs_billing_usage_allowance_policy_quantities"
    add_check_constraint :recording_studio_billing_usage_allowance_policies,
                         "expires_at IS NULL OR expires_at > effective_at",
                         name: "rs_billing_usage_allowance_policy_expiry"

    create_table :recording_studio_billing_usage_ledger_entries, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :usage_period, null: false, type: :uuid,
                                  foreign_key: { to_table: :recording_studio_billing_usage_periods }
      t.references :usage_allocation, type: :uuid,
                                      foreign_key: { to_table: :recording_studio_billing_usage_allocations }
      t.references :usage_credit_grant, type: :uuid,
                                        foreign_key: { to_table: :recording_studio_billing_usage_credit_grants }
      t.references :supersedes, type: :uuid, foreign_key: { to_table: :recording_studio_billing_usage_ledger_entries }
      t.string :entry_kind, null: false
      t.bigint :quantity, null: false
      t.integer :sequence, null: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_usage_ledger_entries, %i[usage_period_id sequence], unique: true,
                                                                                            name: "idx_rs_billing_usage_ledger_period_sequence"
    add_index :recording_studio_billing_usage_ledger_entries, %i[usage_allocation_id entry_kind usage_credit_grant_id], unique: true,
                                                                                                                        where: "usage_allocation_id IS NOT NULL", name: "idx_rs_billing_usage_ledger_allocation_entry"
    add_check_constraint :recording_studio_billing_usage_ledger_entries,
                         "entry_kind IN ('grant', 'allocation', 'overage', 'correction', 'reversal') AND quantity >= 0 AND sequence > 0",
                         name: "rs_billing_usage_ledger_entry_shape"

    create_table :recording_studio_billing_usage_corrections, id: :uuid do |t|
      t.references :usage_allocation, null: false, type: :uuid,
                                      foreign_key: { to_table: :recording_studio_billing_usage_allocations }
      t.references :supersedes, type: :uuid, foreign_key: { to_table: :recording_studio_billing_usage_corrections }
      t.references :tax_calculation, type: :uuid, foreign_key: { to_table: :recording_studio_billing_tax_calculations }
      t.string :correction_kind, null: false
      t.bigint :quantity_delta, null: false
      t.string :reason, null: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_usage_corrections, %i[usage_allocation_id correction_kind], unique: true,
                                                                                                    name: "idx_rs_billing_usage_correction_kind"
    add_check_constraint :recording_studio_billing_usage_corrections,
                         "correction_kind IN ('credit', 'debit', 'void') AND quantity_delta <> 0",
                         name: "rs_billing_usage_correction_delta"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION rs_billing_protect_usage_ledger_entry() RETURNS trigger AS $$
          BEGIN
            IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'usage ledger entries are append-only'; END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_usage_ledger_entry_history
          BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_usage_ledger_entries
          FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_usage_ledger_entry();
        SQL
      end
      direction.down do
        execute "DROP FUNCTION IF EXISTS rs_billing_protect_usage_ledger_entry() CASCADE"
      end
    end
  end
end
