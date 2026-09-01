# frozen_string_literal: true

class AddUniqueInvoiceFinancialCommand < ActiveRecord::Migration[8.1]
  def up
    if index_exists?(:recording_studio_billing_invoices, :financial_command_id,
                     name: "idx_on_financial_command_id_48ec1b5e2a")
      remove_index :recording_studio_billing_invoices, name: "idx_on_financial_command_id_48ec1b5e2a"
    end
    return if index_exists?(:recording_studio_billing_invoices, :financial_command_id,
                            name: "idx_rs_billing_invoice_command")

    add_index :recording_studio_billing_invoices, :financial_command_id,
              unique: true, name: "idx_rs_billing_invoice_command"
  end

  def down
    if index_exists?(:recording_studio_billing_invoices, :financial_command_id,
                     name: "idx_rs_billing_invoice_command")
      remove_index :recording_studio_billing_invoices, name: "idx_rs_billing_invoice_command"
    end
    return if index_exists?(:recording_studio_billing_invoices, :financial_command_id,
                            name: "idx_on_financial_command_id_48ec1b5e2a")

    add_index :recording_studio_billing_invoices, :financial_command_id,
              name: "idx_on_financial_command_id_48ec1b5e2a"
  end
end
