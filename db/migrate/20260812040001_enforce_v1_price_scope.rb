# frozen_string_literal: true

class EnforceV1PriceScope < ActiveRecord::Migration[8.1]
  TABLES = %i[
    recording_studio_billing_prices
    recording_studio_billing_overage_prices
  ].freeze

  def up
    TABLES.each do |table|
      execute <<~SQL.squish
        UPDATE #{table}
        SET scope = 'default'
        WHERE scope <> 'default'
      SQL
      add_check_constraint table, "scope = 'default'", name: "#{table}_v1_scope"
    end
  end

  def down
    TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_v1_scope"
    end
  end
end
