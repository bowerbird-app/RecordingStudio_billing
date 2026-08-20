# frozen_string_literal: true

class CreateAdminRoots < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_roots, id: :uuid do |t|
      t.string :name, null: false

      t.timestamps
    end
    add_index :admin_roots, :name, unique: true
  end
end