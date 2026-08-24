# frozen_string_literal: true

class AddNameToProductsAndBillingOptions < ActiveRecord::Migration[8.1]
  def up
    add_name_to(:recording_studio_billing_products)
    add_name_to(:recording_studio_billing_billing_options)
  end

  def down
    remove_column :recording_studio_billing_products, :name if column_exists?(:recording_studio_billing_products, :name)
    remove_column :recording_studio_billing_billing_options, :name if column_exists?(:recording_studio_billing_billing_options, :name)
  end

  private

  def add_name_to(table_name)
    return if column_exists?(table_name, :name)

    add_column table_name, :name, :string, null: false
  end
end
