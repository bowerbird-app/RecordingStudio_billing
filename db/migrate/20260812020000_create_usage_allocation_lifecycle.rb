# frozen_string_literal: true

class CreateUsageAllocationLifecycle < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_billing_usage_credit_grants, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.string :credit_key, null: false
      t.bigint :quantity, null: false
      t.bigint :remaining_quantity, null: false
      t.datetime :effective_at, null: false
      t.datetime :expires_at
      t.datetime :reversed_at
      t.string :source_key, null: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_usage_credit_grants,
              %i[root_recording_id account_recording_id credit_key effective_at expires_at],
              name: "idx_rs_billing_usage_credit_grants_active"
    add_index :recording_studio_billing_usage_credit_grants, %i[root_recording_id source_key], unique: true,
                                                                                               name: "idx_rs_billing_usage_credit_grant_source"
    add_check_constraint :recording_studio_billing_usage_credit_grants,
                         "quantity > 0 AND remaining_quantity >= 0 AND remaining_quantity <= quantity",
                         name: "rs_billing_usage_credit_grant_quantities"
    add_check_constraint :recording_studio_billing_usage_credit_grants,
                         "expires_at IS NULL OR expires_at > effective_at", name: "rs_billing_usage_credit_grant_expiry"

    create_table :recording_studio_billing_usage_allocations, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :rated_usage, null: false, type: :uuid,
                                 foreign_key: { to_table: :recording_studio_billing_rated_usages }
      t.string :credit_key, null: false
      t.bigint :measured_quantity, null: false
      t.bigint :credited_quantity, null: false, default: 0
      t.bigint :excess_quantity, null: false
      t.string :state, null: false, default: "closed"
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_usage_allocations, :rated_usage_id, unique: true,
                                                                            name: "idx_rs_billing_usage_allocation_rated_usage"
    add_check_constraint :recording_studio_billing_usage_allocations,
                         "measured_quantity >= 0 AND credited_quantity >= 0 AND excess_quantity >= 0 AND credited_quantity + excess_quantity = measured_quantity",
                         name: "rs_billing_usage_allocation_quantities"
    add_check_constraint :recording_studio_billing_usage_allocations, "state IN ('closing', 'closed', 'reversed')",
                         name: "rs_billing_usage_allocation_state"

    create_table :recording_studio_billing_usage_credit_allocations, id: :uuid do |t|
      t.references :usage_allocation, null: false, type: :uuid,
                                      foreign_key: { to_table: :recording_studio_billing_usage_allocations }
      t.references :usage_credit_grant, null: false, type: :uuid,
                                        foreign_key: { to_table: :recording_studio_billing_usage_credit_grants }
      t.bigint :quantity, null: false
      t.timestamps
    end
    add_index :recording_studio_billing_usage_credit_allocations, %i[usage_allocation_id usage_credit_grant_id], unique: true,
                                                                                                                 name: "idx_rs_billing_usage_credit_allocation_unique"
    add_check_constraint :recording_studio_billing_usage_credit_allocations, "quantity > 0",
                         name: "rs_billing_usage_credit_allocation_quantity"

    create_table :recording_studio_billing_overage_calculations, id: :uuid do |t|
      t.references :usage_allocation, null: false, type: :uuid,
                                      foreign_key: { to_table: :recording_studio_billing_usage_allocations }
      t.bigint :excess_quantity, null: false
      t.bigint :amount_minor, null: false
      t.string :currency_code, null: false
      t.integer :currency_exponent, null: false
      t.jsonb :rate_snapshot, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_overage_calculations, :usage_allocation_id, unique: true,
                                                                                    name: "idx_rs_billing_overage_calculation_allocation"
    add_check_constraint :recording_studio_billing_overage_calculations, "excess_quantity >= 0 AND amount_minor >= 0",
                         name: "rs_billing_overage_calculation_amount"

    create_table :recording_studio_billing_provider_references, id: :uuid do |t|
      t.references :financial_command, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.references :provider_account_recording, null: false, type: :uuid,
                                                foreign_key: { to_table: :recording_studio_recordings }
      t.string :provider_adapter_key, null: false
      t.string :environment, null: false
      t.string :reference, null: false
      t.string :reference_type, null: false, default: "operation"
      t.string :remote_type, null: false
      t.string :remote_id, null: false
      t.timestamps
    end
    add_index :recording_studio_billing_provider_references,
              %i[provider_account_recording_id environment remote_type remote_id], unique: true,
                                                                                   name: "idx_rs_billing_provider_reference_scoped_identity"

    create_table :recording_studio_billing_webhook_effects, id: :uuid do |t|
      t.string :provider_adapter_key, null: false
      t.string :event_id, null: false
      t.references :provider_account_recording, null: false, type: :uuid,
                                                foreign_key: { to_table: :recording_studio_recordings }
      t.references :provider_reference, type: :uuid,
                                        foreign_key: { to_table: :recording_studio_billing_provider_references }
      t.string :environment, null: false
      t.uuid :inbound_event_id, null: false
      t.string :handler_name, null: false
      t.string :action_version, null: false
      t.references :financial_command, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.jsonb :safe_payload, null: false, default: {}
      t.datetime :processed_at, null: false
      t.timestamps
    end
    add_index :recording_studio_billing_webhook_effects,
              %i[inbound_event_id provider_account_recording_id environment handler_name action_version], unique: true,
                                                                                                          name: "idx_rs_billing_webhook_effect_receipt_identity"

    create_table :recording_studio_billing_reconciliation_records, id: :uuid do |t|
      t.references :financial_command, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.string :authority, null: false
      t.string :outcome, null: false
      t.jsonb :safe_payload, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_reconciliation_records, :financial_command_id, unique: true,
                                                                                       name: "idx_rs_billing_reconciliation_command"
  end
end
