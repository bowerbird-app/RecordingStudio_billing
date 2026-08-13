# frozen_string_literal: true

class EnforceCreditDebitBalances < ActiveRecord::Migration[8.1]
  def up
    execute credit_ledger_trigger(include_balance_check: true)
  end

  def down
    execute credit_ledger_trigger(include_balance_check: false)
  end

  private

  def credit_ledger_trigger(include_balance_check:)
    balance_check = if include_balance_check
                      <<~SQL
                        PERFORM pg_advisory_xact_lock(hashtextextended(
                          'recording-studio-billing:credits:' || NEW.root_recording_id::text || ':' || NEW.account_recording_id::text || ':' || NEW.product_recording_id::text,
                          0
                        ));
                        IF COALESCE((
                          SELECT SUM(amount) FROM recording_studio_billing_credit_ledger_entries
                          WHERE root_recording_id = NEW.root_recording_id AND account_recording_id = NEW.account_recording_id
                            AND product_recording_id = NEW.product_recording_id
                        ), 0) + NEW.amount < 0 THEN
                          RAISE EXCEPTION 'credit debit would make the balance negative';
                        END IF;
                      SQL
                    end

    <<~SQL
      CREATE OR REPLACE FUNCTION rs_billing_protect_credit_ledger_entry() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'credit ledger entries are append-only'; END IF;
        IF NEW.direction = 'credit' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_purchase_effects effect
            JOIN recording_studio_billing_purchases purchase ON purchase.id = effect.purchase_id
            WHERE effect.id = NEW.purchase_effect_id AND effect.effect_kind = 'credit_pack'
              AND effect.root_recording_id = NEW.root_recording_id AND effect.account_recording_id = NEW.account_recording_id
              AND effect.manifest_digest = NEW.manifest_digest AND purchase.manifest_digest = NEW.manifest_digest
              AND purchase.product_recording_id = NEW.product_recording_id
              AND purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.credit_key, 'definition', 'type'] = '"allowance"'::jsonb
              AND jsonb_typeof(purchase.commercial_snapshot #> ARRAY['canonical_data', 'features', NEW.credit_key, 'value']) = 'number'
              AND (purchase.commercial_snapshot #>> ARRAY['canonical_data', 'features', NEW.credit_key, 'value'])::bigint * purchase.quantity = NEW.amount
          ) THEN RAISE EXCEPTION 'credit ledger source authority is invalid'; END IF;
        ELSIF NEW.direction = 'debit' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_usage_events event
            WHERE event.id = NEW.usage_event_id AND event.root_recording_id = NEW.root_recording_id
              AND event.account_recording_id = NEW.account_recording_id AND event.usage_key = NEW.credit_key
              AND event.idempotency_key = NEW.idempotency_key
          ) OR NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_credit_ledger_entries credit
            WHERE credit.direction = 'credit' AND credit.root_recording_id = NEW.root_recording_id
              AND credit.account_recording_id = NEW.account_recording_id AND credit.product_recording_id = NEW.product_recording_id
              AND credit.credit_key = NEW.credit_key AND credit.manifest_digest = NEW.manifest_digest
          ) OR NOT rs_billing_safe_financial_json(NEW.safe_metadata) THEN
            RAISE EXCEPTION 'credit debit source authority is invalid';
          END IF;
          #{balance_check}
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end
end
