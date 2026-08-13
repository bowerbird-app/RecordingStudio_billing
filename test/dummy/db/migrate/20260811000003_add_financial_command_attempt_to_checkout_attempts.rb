# frozen_string_literal: true

class AddFinancialCommandAttemptToCheckoutAttempts < ActiveRecord::Migration[8.1]
  def change
    add_reference :recording_studio_billing_checkout_attempts, :financial_command_attempt,
                  type: :uuid, foreign_key: { to_table: :recording_studio_billing_financial_command_attempts }
  end
end