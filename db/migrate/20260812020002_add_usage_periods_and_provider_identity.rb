# frozen_string_literal: true

class AddUsagePeriodsAndProviderIdentity < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_billing_usage_periods, id: :uuid do |t|
      t.references :root_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.references :account_recording, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.string :usage_key, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :state, null: false, default: "open"
      t.datetime :closed_at
      t.jsonb :safe_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_usage_periods,
              %i[root_recording_id account_recording_id usage_key starts_at ends_at], unique: true,
                                                                                      name: "idx_rs_billing_usage_period_scope"
    add_check_constraint :recording_studio_billing_usage_periods, "ends_at > starts_at",
                         name: "rs_billing_usage_period_window"
    add_check_constraint :recording_studio_billing_usage_periods,
                         "state IN ('open', 'closing', 'closed', 'submitted', 'invoiced', 'reconciled', 'requires_review')",
                         name: "rs_billing_usage_period_state"

    create_table :recording_studio_billing_reconciliation_issues, id: :uuid do |t|
      t.references :financial_command, type: :uuid,
                                       foreign_key: { to_table: :recording_studio_billing_financial_commands }
      t.references :provider_account_recording, type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
      t.string :authority, null: false
      t.string :kind, null: false
      t.string :state, null: false, default: "open"
      t.string :provider_adapter_key
      t.string :event_id
      t.string :environment
      t.uuid :inbound_event_id
      t.string :handler_name
      t.string :action_version
      t.jsonb :safe_payload, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_reconciliation_issues, %i[financial_command_id kind], unique: true,
                                                                                              name: "idx_rs_billing_reconciliation_issue_identity"
    add_index :recording_studio_billing_reconciliation_issues,
              %i[provider_account_recording_id environment inbound_event_id handler_name action_version kind],
              unique: true, where: "financial_command_id IS NULL",
              name: "idx_rs_billing_unresolved_webhook_receipt"
    add_check_constraint :recording_studio_billing_reconciliation_issues,
                         "state IN ('open', 'resolved', 'ignored')", name: "rs_billing_reconciliation_issue_state"
  end
end
