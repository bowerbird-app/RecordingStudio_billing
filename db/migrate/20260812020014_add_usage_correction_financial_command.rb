# frozen_string_literal: true

class AddUsageCorrectionFinancialCommand < ActiveRecord::Migration[8.1]
  def change
    add_reference :recording_studio_billing_usage_corrections, :financial_command, type: :uuid,
                                                                                   foreign_key: { to_table: :recording_studio_billing_financial_commands }
    add_index :recording_studio_billing_usage_corrections, :financial_command_id, unique: true,
                                                                                  where: "financial_command_id IS NOT NULL", name: "idx_rs_billing_usage_correction_command"
  end
end
