# frozen_string_literal: true

class CreateCommercialFinancialLifecycle < ActiveRecord::Migration[8.1]
  def change
    remove_index :recording_studio_billing_subscriptions, name: "idx_rs_billing_subscription_account"

    add_column :recording_studio_billing_plan_updates, :preview, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_plan_updates, :confirmation, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_plan_updates, :effective_at, :datetime
    add_column :recording_studio_billing_plan_updates, :audience, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_plan_updates, :allowance_policy, :string, null: false, default: "preserve"
    add_column :recording_studio_billing_plan_updates, :execution_state, :string, null: false, default: "draft"
    add_column :recording_studio_billing_plan_updates, :idempotency_key, :string
    add_column :recording_studio_billing_plan_updates, :reconciliation_state, :string, null: false,
                                                                                       default: "not_required"
    add_check_constraint :recording_studio_billing_plan_updates, "allowance_policy IN ('preserve', 'replace', 'reconcile')",
                         name: "rs_billing_plan_update_allowance_policy"
    add_check_constraint :recording_studio_billing_plan_updates, "execution_state IN ('draft', 'previewed', 'confirmed', 'scheduled', 'applying', 'completed', 'requires_review', 'failed')",
                         name: "rs_billing_plan_update_execution_state"
    add_index :recording_studio_billing_plan_updates, :idempotency_key, unique: true,
                                                                        where: "idempotency_key IS NOT NULL", name: "idx_rs_billing_plan_update_idempotency"

    create_table :recording_studio_billing_subscription_items, id: :uuid do |t|
      t.references :subscription, null: false, type: :uuid,
                                  foreign_key: { to_table: :recording_studio_billing_subscriptions }
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.string :line_key, null: false
      t.string :state, null: false, default: "active"
      t.timestamps
    end
    add_index :recording_studio_billing_subscription_items, %i[subscription_id line_key], unique: true,
                                                                                          name: "idx_rs_billing_subscription_item_line"
    add_check_constraint :recording_studio_billing_subscription_items, "state IN ('active', 'cancelled')",
                         name: "rs_billing_subscription_item_state"

    add_reference :recording_studio_billing_subscription_item_versions, :subscription_item, type: :uuid,
                                                                                            foreign_key: { to_table: :recording_studio_billing_subscription_items }
    add_index :recording_studio_billing_subscription_item_versions, %i[subscription_item_id version_number], unique: true,
                                                                                                             name: "idx_rs_billing_subscription_item_version"

    create_table :recording_studio_billing_subscription_change_intents, id: :uuid do |t|
      t.references :subscription, null: false, type: :uuid,
                                  foreign_key: { to_table: :recording_studio_billing_subscriptions }
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :financial_command, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.string :local_idempotency_key, null: false
      t.string :request_fingerprint, null: false
      t.string :state, null: false, default: "pending"
      t.string :change_kind, null: false
      t.datetime :effective_at
      t.jsonb :change_set, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_subscription_change_intents, %i[root_recording_id local_idempotency_key], unique: true,
                                                                                                                  name: "idx_rs_billing_subscription_change_idempotency"
    add_check_constraint :recording_studio_billing_subscription_change_intents,
                         "state IN ('pending', 'scheduled', 'executing', 'applied', 'cancelled', 'failed', 'requires_review')",
                         name: "rs_billing_subscription_change_state"

    create_table :recording_studio_billing_payments, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :financial_command, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.string :provider_reference
      t.string :currency_code, null: false
      t.bigint :amount_minor, null: false
      t.string :state, null: false
      t.jsonb :safe_snapshot, null: false, default: {}
      t.datetime :recorded_at, null: false
      t.timestamps
    end
    add_index :recording_studio_billing_payments, :financial_command_id, unique: true,
                                                                         name: "idx_rs_billing_payment_command"
    add_check_constraint :recording_studio_billing_payments, "amount_minor >= 0 AND currency_code ~ '^[A-Z]{3}$'",
                         name: "rs_billing_payment_amount"

    create_table :recording_studio_billing_payment_allocations, id: :uuid do |t|
      t.references :payment, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_payments }
      t.references :invoice, type: :uuid
      t.bigint :amount_minor, null: false
      t.timestamps
    end
    add_check_constraint :recording_studio_billing_payment_allocations, "amount_minor > 0",
                         name: "rs_billing_payment_allocation_amount"

    create_table :recording_studio_billing_invoices, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :financial_command, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.string :currency_code, null: false
      t.bigint :total_minor, null: false
      t.string :state, null: false
      t.datetime :issued_at, null: false
      t.jsonb :safe_snapshot, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :recording_studio_billing_invoices, "total_minor >= 0 AND currency_code ~ '^[A-Z]{3}$'",
                         name: "rs_billing_invoice_amount"

    create_table :recording_studio_billing_invoice_lines, id: :uuid do |t|
      t.references :invoice, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_invoices }
      t.string :description, null: false
      t.string :currency_code, null: false
      t.bigint :amount_minor, null: false
      t.integer :quantity, null: false
      t.string :manifest_digest
      t.jsonb :safe_snapshot, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :recording_studio_billing_invoice_lines, "amount_minor >= 0 AND quantity > 0 AND currency_code ~ '^[A-Z]{3}$'",
                         name: "rs_billing_invoice_line_amount"

    create_table :recording_studio_billing_refund_intents, id: :uuid do |t|
      t.references :payment, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_payments }
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :financial_command, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.string :local_idempotency_key, null: false
      t.string :state, null: false, default: "pending"
      t.bigint :amount_minor, null: false
      t.string :currency_code, null: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_refund_intents, %i[root_recording_id local_idempotency_key], unique: true,
                                                                                                     name: "idx_rs_billing_refund_intent_idempotency"

    create_table :recording_studio_billing_refunds, id: :uuid do |t|
      t.references :refund_intent, null: false, type: :uuid,
                                   foreign_key: { to_table: :recording_studio_billing_refund_intents }
      t.references :payment, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_payments }
      t.references :financial_command, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.bigint :amount_minor, null: false
      t.string :currency_code, null: false
      t.string :provider_reference
      t.datetime :recorded_at, null: false
      t.jsonb :safe_snapshot, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_refunds, :refund_intent_id, unique: true,
                                                                    name: "idx_rs_billing_refund_projection"

    create_table :recording_studio_billing_adjustment_intents, id: :uuid do |t|
      t.references :invoice, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_invoices }
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :financial_command, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.string :local_idempotency_key, null: false
      t.string :state, null: false, default: "pending"
      t.string :kind, null: false
      t.bigint :amount_minor, null: false
      t.string :currency_code, null: false
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_adjustment_intents, %i[root_recording_id local_idempotency_key], unique: true,
                                                                                                         name: "idx_rs_billing_adjustment_intent_idempotency"
    add_check_constraint :recording_studio_billing_adjustment_intents, "kind IN ('credit', 'write_off') AND amount_minor > 0",
                         name: "rs_billing_adjustment_intent_kind"

    create_table :recording_studio_billing_financial_adjustments, id: :uuid do |t|
      t.references :adjustment_intent, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_adjustment_intents }
      t.references :invoice, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_billing_invoices }
      t.references :financial_command, null: false, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.string :kind, null: false
      t.bigint :amount_minor, null: false
      t.string :currency_code, null: false
      t.datetime :recorded_at, null: false
      t.jsonb :safe_snapshot, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_financial_adjustments, :adjustment_intent_id, unique: true,
                                                                                      name: "idx_rs_billing_adjustment_projection"

    create_table :recording_studio_billing_plan_update_applications, id: :uuid do |t|
      t.references :plan_update, null: false, type: :uuid,
                                 foreign_key: { to_table: :recording_studio_billing_plan_updates }
      t.references :subscription, null: false, type: :uuid,
                                  foreign_key: { to_table: :recording_studio_billing_subscriptions }
      t.references :subscription_change_intent, null: false, type: :uuid,
                                                foreign_key: { to_table: :recording_studio_billing_subscription_change_intents }
      t.string :state, null: false, default: "pending"
      t.timestamps
    end
    add_index :recording_studio_billing_plan_update_applications, %i[plan_update_id subscription_id], unique: true,
                                                                                                      name: "idx_rs_billing_plan_update_subscription"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION rs_billing_protect_commercial_projection() RETURNS trigger AS $$
          BEGIN
            RAISE EXCEPTION 'commercial financial projections are immutable';
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_payment_history BEFORE UPDATE OR DELETE ON recording_studio_billing_payments FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_commercial_projection();
          CREATE TRIGGER rs_billing_payment_allocation_history BEFORE UPDATE OR DELETE ON recording_studio_billing_payment_allocations FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_commercial_projection();
          CREATE TRIGGER rs_billing_invoice_history BEFORE UPDATE OR DELETE ON recording_studio_billing_invoices FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_commercial_projection();
          CREATE TRIGGER rs_billing_invoice_line_history BEFORE UPDATE OR DELETE ON recording_studio_billing_invoice_lines FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_commercial_projection();
          CREATE TRIGGER rs_billing_refund_history BEFORE UPDATE OR DELETE ON recording_studio_billing_refunds FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_commercial_projection();
          CREATE TRIGGER rs_billing_adjustment_history BEFORE UPDATE OR DELETE ON recording_studio_billing_financial_adjustments FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_commercial_projection();
        SQL
      end
      direction.down do
        execute "DROP FUNCTION IF EXISTS rs_billing_protect_commercial_projection() CASCADE"
      end
    end
  end
end
