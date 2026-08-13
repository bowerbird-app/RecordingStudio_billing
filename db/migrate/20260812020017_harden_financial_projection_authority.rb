# frozen_string_literal: true

class HardenFinancialProjectionAuthority < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION rs_billing_validate_financial_lifecycle_authority() RETURNS trigger AS $$
      DECLARE reserved_amount bigint;
      BEGIN
        IF TG_TABLE_NAME = 'recording_studio_billing_payments' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_financial_commands command
            WHERE command.id = NEW.financial_command_id AND command.root_recording_id = NEW.root_recording_id
              AND command.account_recording_id = NEW.account_recording_id
          ) THEN RAISE EXCEPTION 'payment command authority is invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'recording_studio_billing_invoices' THEN
          IF NEW.financial_command_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_financial_commands command
            WHERE command.id = NEW.financial_command_id AND command.root_recording_id = NEW.root_recording_id
              AND command.account_recording_id = NEW.account_recording_id
          ) THEN RAISE EXCEPTION 'invoice command authority is invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'recording_studio_billing_payment_allocations' THEN
          PERFORM 1 FROM recording_studio_billing_payments WHERE id = NEW.payment_id FOR UPDATE;
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_payments payment
            JOIN recording_studio_billing_invoices invoice ON invoice.id = NEW.invoice_id
            WHERE payment.id = NEW.payment_id AND payment.root_recording_id = invoice.root_recording_id
              AND payment.account_recording_id = invoice.account_recording_id
          ) OR NEW.amount_minor + COALESCE((
            SELECT SUM(amount_minor) FROM recording_studio_billing_payment_allocations
            WHERE payment_id = NEW.payment_id AND id IS DISTINCT FROM NEW.id
          ), 0) > (SELECT amount_minor FROM recording_studio_billing_payments WHERE id = NEW.payment_id)
          THEN RAISE EXCEPTION 'payment allocation authority is invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'recording_studio_billing_refund_intents' THEN
          PERFORM 1 FROM recording_studio_billing_payments WHERE id = NEW.payment_id FOR UPDATE;
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_payments payment
            WHERE payment.id = NEW.payment_id AND payment.root_recording_id = NEW.root_recording_id
              AND payment.account_recording_id = NEW.account_recording_id AND payment.currency_code = NEW.currency_code
          ) OR NEW.amount_minor + COALESCE((
            SELECT SUM(amount_minor) FROM recording_studio_billing_refund_intents
            WHERE payment_id = NEW.payment_id AND state IN ('pending', 'executing', 'completed') AND id IS DISTINCT FROM NEW.id
          ), 0) > (SELECT amount_minor FROM recording_studio_billing_payments WHERE id = NEW.payment_id)
          THEN RAISE EXCEPTION 'refund authority is invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'recording_studio_billing_adjustment_intents' THEN
          PERFORM 1 FROM recording_studio_billing_invoices WHERE id = NEW.invoice_id FOR UPDATE;
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_invoices invoice
            WHERE invoice.id = NEW.invoice_id AND invoice.root_recording_id = NEW.root_recording_id
              AND invoice.account_recording_id = NEW.account_recording_id AND invoice.currency_code = NEW.currency_code
          ) THEN RAISE EXCEPTION 'adjustment authority is invalid'; END IF;
          IF NEW.kind IN ('credit', 'write_off') AND NEW.amount_minor + COALESCE((
            SELECT SUM(amount_minor) FROM recording_studio_billing_adjustment_intents
            WHERE invoice_id = NEW.invoice_id AND kind IN ('credit', 'write_off')
              AND state IN ('pending', 'executing', 'completed') AND id IS DISTINCT FROM NEW.id
          ), 0) > (SELECT total_minor FROM recording_studio_billing_invoices WHERE id = NEW.invoice_id)
          THEN RAISE EXCEPTION 'adjustment capacity is invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'recording_studio_billing_refunds' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_refund_intents intent
            JOIN recording_studio_billing_payments payment ON payment.id = intent.payment_id
            WHERE intent.id = NEW.refund_intent_id AND payment.id = NEW.payment_id
              AND intent.financial_command_id = NEW.financial_command_id AND intent.amount_minor = NEW.amount_minor
              AND intent.currency_code = NEW.currency_code
          ) THEN RAISE EXCEPTION 'refund projection authority is invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'recording_studio_billing_financial_adjustments' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_adjustment_intents intent
            WHERE intent.id = NEW.adjustment_intent_id AND intent.invoice_id = NEW.invoice_id
              AND intent.financial_command_id = NEW.financial_command_id AND intent.kind = NEW.kind
              AND intent.amount_minor = NEW.amount_minor AND intent.currency_code = NEW.currency_code
          ) THEN RAISE EXCEPTION 'adjustment projection authority is invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'recording_studio_billing_plan_update_applications' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_plan_update_runs run
            JOIN recording_studio_billing_subscription_change_intents change ON change.id = NEW.subscription_change_intent_id
            WHERE run.id = NEW.plan_update_run_id AND run.plan_update_id = NEW.plan_update_id
              AND change.subscription_id = NEW.subscription_id
          ) THEN RAISE EXCEPTION 'plan update application authority is invalid'; END IF;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
