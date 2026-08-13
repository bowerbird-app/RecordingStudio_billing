# frozen_string_literal: true

class EnforceCommercialFinancialAuthority < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE recording_studio_billing_subscriptions subscription
      SET provider_account_recording_id = version.provider_account_recording_id,
          currency_code = version.currency_code,
          collection_method = version.commercial_snapshot #>> '{canonical_data,billing_option,collection_method}',
          market_recording_id = (version.commercial_snapshot #>> '{canonical_data,references,market_recording_id}')::uuid,
          execution_group_fingerprint = encode(digest(concat_ws(':', version.provider_account_recording_id, version.currency_code,
            version.commercial_snapshot #>> '{canonical_data,billing_option,collection_method}',
            version.commercial_snapshot #>> '{canonical_data,references,market_recording_id}', subscription.billing_anchor, subscription.payment_terms_days), 'sha256'), 'hex')
      FROM recording_studio_billing_subscription_item_versions version
      WHERE version.subscription_id = subscription.id AND subscription.provider_account_recording_id IS NULL;
    SQL
    change_column_null :recording_studio_billing_subscriptions, :provider_account_recording_id, false
    change_column_null :recording_studio_billing_subscriptions, :currency_code, false
    change_column_null :recording_studio_billing_subscriptions, :collection_method, false
    change_column_null :recording_studio_billing_subscriptions, :market_recording_id, false
    change_column_null :recording_studio_billing_subscriptions, :execution_group_fingerprint, false
    change_column_null :recording_studio_billing_plan_update_applications, :plan_update_run_id, false
    add_check_constraint :recording_studio_billing_subscriptions, "currency_code ~ '^[A-Z]{3}$' AND collection_method IN ('automatic', 'invoice') AND execution_group_fingerprint ~ '^[0-9a-f]{64}$'",
                         name: "rs_billing_subscription_execution_identity"
    execute <<~SQL
      CREATE FUNCTION rs_billing_validate_financial_lifecycle_authority() RETURNS trigger AS $$
      BEGIN
        IF TG_TABLE_NAME = 'recording_studio_billing_payments' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_financial_commands command
          WHERE command.id = NEW.financial_command_id AND command.root_recording_id = NEW.root_recording_id
            AND command.account_recording_id = NEW.account_recording_id
        ) THEN RAISE EXCEPTION 'payment command authority is invalid'; END IF;
        IF TG_TABLE_NAME = 'recording_studio_billing_invoices' AND NEW.financial_command_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_financial_commands command
          WHERE command.id = NEW.financial_command_id AND command.root_recording_id = NEW.root_recording_id
            AND command.account_recording_id = NEW.account_recording_id
        ) THEN RAISE EXCEPTION 'invoice command authority is invalid'; END IF;
        IF TG_TABLE_NAME = 'recording_studio_billing_payment_allocations' AND NEW.invoice_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_payments payment JOIN recording_studio_billing_invoices invoice ON invoice.id = NEW.invoice_id
          WHERE payment.id = NEW.payment_id AND payment.root_recording_id = invoice.root_recording_id
            AND payment.account_recording_id = invoice.account_recording_id AND NEW.amount_minor <= payment.amount_minor
        ) THEN RAISE EXCEPTION 'payment allocation authority is invalid'; END IF;
        IF TG_TABLE_NAME = 'recording_studio_billing_refund_intents' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_payments payment
          WHERE payment.id = NEW.payment_id AND payment.root_recording_id = NEW.root_recording_id
            AND payment.account_recording_id = NEW.account_recording_id AND payment.currency_code = NEW.currency_code
        ) THEN RAISE EXCEPTION 'refund authority is invalid'; END IF;
        IF TG_TABLE_NAME = 'recording_studio_billing_adjustment_intents' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_invoices invoice
          WHERE invoice.id = NEW.invoice_id AND invoice.root_recording_id = NEW.root_recording_id
            AND invoice.account_recording_id = NEW.account_recording_id AND invoice.currency_code = NEW.currency_code
        ) THEN RAISE EXCEPTION 'adjustment authority is invalid'; END IF;
        IF TG_TABLE_NAME = 'recording_studio_billing_plan_update_applications' AND NOT EXISTS (
          SELECT 1 FROM recording_studio_billing_plan_update_runs run
          JOIN recording_studio_billing_subscription_change_intents change ON change.id = NEW.subscription_change_intent_id
          WHERE run.id = NEW.plan_update_run_id AND run.plan_update_id = NEW.plan_update_id
            AND change.subscription_id = NEW.subscription_id
        ) THEN RAISE EXCEPTION 'plan update application authority is invalid'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_payment_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_payments FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_financial_lifecycle_authority();
      CREATE TRIGGER rs_billing_invoice_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_invoices FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_financial_lifecycle_authority();
      CREATE TRIGGER rs_billing_payment_allocation_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_payment_allocations FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_financial_lifecycle_authority();
      CREATE TRIGGER rs_billing_refund_intent_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_refund_intents FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_financial_lifecycle_authority();
      CREATE TRIGGER rs_billing_adjustment_intent_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_adjustment_intents FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_financial_lifecycle_authority();
      CREATE TRIGGER rs_billing_plan_update_application_authority BEFORE INSERT OR UPDATE ON recording_studio_billing_plan_update_applications FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_financial_lifecycle_authority();
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS rs_billing_validate_financial_lifecycle_authority() CASCADE"
  end
end
