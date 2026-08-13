# frozen_string_literal: true

class HardenCommercialFinancialLifecycle < ActiveRecord::Migration[8.1]
  CHANGE_STATES = %w[draft validated awaiting_confirmation pending_provider scheduled applied failed requires_review
                     cancelled expired].freeze

  def change
    add_column :recording_studio_billing_subscriptions, :provider_account_recording_id, :uuid
    add_column :recording_studio_billing_subscriptions, :currency_code, :string
    add_column :recording_studio_billing_subscriptions, :collection_method, :string
    add_column :recording_studio_billing_subscriptions, :billing_anchor, :string, null: false, default: "checkout"
    add_column :recording_studio_billing_subscriptions, :payment_terms_days, :integer, null: false, default: 0
    add_column :recording_studio_billing_subscriptions, :market_recording_id, :uuid
    add_column :recording_studio_billing_subscriptions, :execution_group_fingerprint, :string
    add_foreign_key :recording_studio_billing_subscriptions, :recording_studio_recordings,
                    column: :provider_account_recording_id
    add_foreign_key :recording_studio_billing_subscriptions, :recording_studio_recordings, column: :market_recording_id
    add_index :recording_studio_billing_subscriptions,
              %i[root_recording_id account_recording_id execution_group_fingerprint], unique: true,
                                                                                      name: "idx_rs_billing_subscription_execution_group"

    add_column :recording_studio_billing_subscription_change_intents, :current_manifest_digest, :string
    add_column :recording_studio_billing_subscription_change_intents, :proposed_manifest_digest, :string
    add_column :recording_studio_billing_subscription_change_intents, :frozen_terms, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_subscription_change_intents, :provider_decision, :jsonb, null: false,
                                                                                                  default: {}
    add_column :recording_studio_billing_subscription_change_intents, :outcome, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_subscription_change_intents, :timing, :string, null: false,
                                                                                        default: "immediate"
    add_column :recording_studio_billing_subscription_change_intents, :proration_policy, :string, null: false,
                                                                                                  default: "none"
    add_check_constraint :recording_studio_billing_subscription_change_intents,
                         "timing IN ('immediate', 'next_period')", name: "rs_billing_subscription_change_timing"

    add_column :recording_studio_billing_plan_updates, :replacement_manifest_digest, :string
    add_column :recording_studio_billing_plan_updates, :replacement_configuration, :jsonb, null: false, default: {}
    create_table :recording_studio_billing_plan_update_runs, id: :uuid do |t|
      t.references :plan_update, null: false, type: :uuid,
                                 foreign_key: { to_table: :recording_studio_billing_plan_updates }
      t.string :idempotency_key, null: false
      t.string :request_fingerprint, null: false
      t.string :state, null: false, default: "draft"
      t.datetime :scheduled_at
      t.jsonb :preview, null: false, default: {}
      t.jsonb :confirmation, null: false, default: {}
      t.jsonb :reconciliation, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_billing_plan_update_runs, %i[plan_update_id idempotency_key], unique: true,
                                                                                              name: "idx_rs_billing_plan_update_run_idempotency"
    add_check_constraint :recording_studio_billing_plan_update_runs,
                         "state IN ('draft', 'previewed', 'awaiting_confirmation', 'scheduled', 'applying', 'applied', 'failed', 'requires_review')",
                         name: "rs_billing_plan_update_run_state"
    add_reference :recording_studio_billing_plan_update_applications, :plan_update_run, type: :uuid,
                                                                                        foreign_key: { to_table: :recording_studio_billing_plan_update_runs }

    add_column :recording_studio_billing_payments, :subtotal_minor, :bigint
    add_column :recording_studio_billing_payments, :discount_minor, :bigint
    add_column :recording_studio_billing_payments, :tax_minor, :bigint
    add_reference :recording_studio_billing_payments, :invoice, type: :uuid,
                                                                foreign_key: { to_table: :recording_studio_billing_invoices }
    add_column :recording_studio_billing_invoices, :provider_reference, :string
    add_column :recording_studio_billing_invoices, :subtotal_minor, :bigint
    add_column :recording_studio_billing_invoices, :discount_minor, :bigint
    add_column :recording_studio_billing_invoices, :tax_minor, :bigint
    add_reference :recording_studio_billing_invoices, :subscription, type: :uuid,
                                                                     foreign_key: { to_table: :recording_studio_billing_subscriptions }
    add_reference :recording_studio_billing_invoices, :purchase, type: :uuid,
                                                                 foreign_key: { to_table: :recording_studio_billing_purchases }
    add_column :recording_studio_billing_refund_intents, :provider_account_recording_id, :uuid
    add_column :recording_studio_billing_refund_intents, :request_fingerprint, :string
    add_column :recording_studio_billing_refund_intents, :reason, :string
    add_column :recording_studio_billing_refund_intents, :actor_reference, :string
    add_column :recording_studio_billing_refund_intents, :tax_treatment, :string, null: false,
                                                                                  default: "provider_default"
    add_column :recording_studio_billing_refund_intents, :reversal_policy, :string, null: false, default: "none"
    add_column :recording_studio_billing_refund_intents, :line_allocation, :jsonb, null: false, default: {}
    add_foreign_key :recording_studio_billing_refund_intents, :recording_studio_recordings,
                    column: :provider_account_recording_id
    add_column :recording_studio_billing_adjustment_intents, :request_fingerprint, :string
    add_column :recording_studio_billing_adjustment_intents, :reason, :string
    add_column :recording_studio_billing_adjustment_intents, :actor_reference, :string
    add_column :recording_studio_billing_adjustment_intents, :tax_treatment, :string, null: false,
                                                                                      default: "provider_default"
    add_column :recording_studio_billing_adjustment_intents, :approved_authority, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_adjustment_intents, :affected_reference, :jsonb, null: false, default: {}
    execute "ALTER TABLE recording_studio_billing_adjustment_intents DROP CONSTRAINT rs_billing_adjustment_intent_kind"
    add_check_constraint :recording_studio_billing_adjustment_intents, "kind IN ('credit', 'debit', 'write_off') AND amount_minor > 0",
                         name: "rs_billing_adjustment_intent_kind"

    execute "UPDATE recording_studio_billing_subscription_item_versions SET subscription_item_id = item.id FROM recording_studio_billing_subscription_items item WHERE item.subscription_id = recording_studio_billing_subscription_item_versions.subscription_id AND item.line_key = recording_studio_billing_subscription_item_versions.line_key AND recording_studio_billing_subscription_item_versions.subscription_item_id IS NULL"
    change_column_null :recording_studio_billing_subscription_item_versions, :subscription_item_id, false

    reversible do |direction|
      direction.up do
        execute "ALTER TABLE recording_studio_billing_subscription_change_intents DROP CONSTRAINT rs_billing_subscription_change_state"
        execute "ALTER TABLE recording_studio_billing_subscription_change_intents ADD CONSTRAINT rs_billing_subscription_change_state CHECK (state IN (#{CHANGE_STATES.map do |state|
          connection.quote(state)
        end.join(', ')}))"
        execute <<~SQL
          CREATE FUNCTION rs_billing_validate_commercial_lifecycle_authority() RETURNS trigger AS $$
          BEGIN
            IF TG_TABLE_NAME = 'recording_studio_billing_subscription_items' THEN
              IF NOT EXISTS (
                SELECT 1 FROM recording_studio_billing_subscriptions subscription
                WHERE subscription.id = NEW.subscription_id AND subscription.root_recording_id = NEW.root_recording_id
                  AND subscription.account_recording_id = NEW.account_recording_id
              ) THEN RAISE EXCEPTION 'subscription item authority is invalid'; END IF;
            ELSIF TG_TABLE_NAME = 'recording_studio_billing_subscription_item_versions' THEN
              IF NOT EXISTS (
                SELECT 1 FROM recording_studio_billing_subscription_items item
                WHERE item.id = NEW.subscription_item_id AND item.subscription_id = NEW.subscription_id
                  AND item.root_recording_id = NEW.root_recording_id AND item.account_recording_id = NEW.account_recording_id
                  AND item.line_key = NEW.line_key
              ) THEN RAISE EXCEPTION 'subscription item version authority is invalid'; END IF;
            ELSIF TG_TABLE_NAME = 'recording_studio_billing_subscription_change_intents' THEN
              IF NOT EXISTS (
                SELECT 1 FROM recording_studio_billing_subscriptions subscription
                WHERE subscription.id = NEW.subscription_id AND subscription.root_recording_id = NEW.root_recording_id
                  AND subscription.account_recording_id = NEW.account_recording_id
              ) THEN RAISE EXCEPTION 'subscription change authority is invalid'; END IF;
            END IF;
            RETURN NEW;
          END;
          $$ LANGUAGE plpgsql;
          CREATE TRIGGER rs_billing_subscription_item_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_subscription_items FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_commercial_lifecycle_authority();
          CREATE TRIGGER rs_billing_subscription_item_version_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_subscription_item_versions FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_commercial_lifecycle_authority();
          CREATE TRIGGER rs_billing_subscription_change_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_subscription_change_intents FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_commercial_lifecycle_authority();
        SQL
      end
      direction.down { execute "DROP FUNCTION IF EXISTS rs_billing_validate_commercial_lifecycle_authority() CASCADE" }
    end
  end
end
