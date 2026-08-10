# frozen_string_literal: true

class CreateBillingFoundationRoots < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_roots, id: :uuid do |t|
      t.string :name, null: false

      t.timestamps
    end
    add_index :admin_roots, :name, unique: true

    create_table :recording_studio_billing_accounts, id: :uuid do |t|
      t.string :name, null: false

      t.timestamps
    end
    add_index :recording_studio_billing_accounts, :name, unique: true

    create_table :recording_studio_billing_billing_admins, id: :uuid do |t|
      t.string :key, null: false

      t.timestamps
    end
    add_index :recording_studio_billing_billing_admins, :key, unique: true
  end
end
