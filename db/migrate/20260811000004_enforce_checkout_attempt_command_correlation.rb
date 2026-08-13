# frozen_string_literal: true

class EnforceCheckoutAttemptCommandCorrelation < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION rs_billing_validate_checkout_attempt_command_correlation() RETURNS trigger AS $$
      BEGIN
        IF NEW.financial_command_attempt_id IS NOT NULL AND NOT EXISTS (
          SELECT 1
          FROM recording_studio_billing_financial_command_attempts command_attempt
          WHERE command_attempt.id = NEW.financial_command_attempt_id
            AND command_attempt.financial_command_id = NEW.financial_command_id
            AND command_attempt.attempt_number = NEW.attempt_number
        ) THEN
          RAISE EXCEPTION 'checkout attempt must match its financial command attempt';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_checkout_attempt_command_correlation
      BEFORE INSERT OR UPDATE OF financial_command_attempt_id
      ON recording_studio_billing_checkout_attempts
      FOR EACH ROW EXECUTE FUNCTION rs_billing_validate_checkout_attempt_command_correlation();
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS rs_billing_validate_checkout_attempt_command_correlation() CASCADE"
  end
end
