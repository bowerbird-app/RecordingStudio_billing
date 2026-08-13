# frozen_string_literal: true

class AddAccountBillingPreferences < ActiveRecord::Migration[8.1]
  def change
    change_table :recording_studio_billing_accounts, bulk: true do |table|
      table.string :contact_email
      table.string :billing_country_code, limit: 2
      table.string :billing_currency_code, limit: 3
      table.string :locale, limit: 16
      table.string :time_zone, limit: 64
      table.string :tax_location_country_code, limit: 2
      table.string :tax_location_region_code, limit: 16
      table.string :tax_location_postal_code, limit: 32
    end
  end
end
