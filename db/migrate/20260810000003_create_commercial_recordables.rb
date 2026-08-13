# frozen_string_literal: true

class CreateCommercialRecordables < ActiveRecord::Migration[8.1]
  RECORDINGS = :recording_studio_recordings
  STATES = %w[draft published retired].freeze

  def change
    create_provider_accounts
    create_markets
    create_products
    create_billing_options
    create_prices
    create_overage_prices
    create_features
    create_feature_overrides
    create_product_rules
    create_plan_updates
    create_usage_units
    create_meters
    create_rate_cards
    create_rates
    create_cost_cards
    create_cost_rates
  end

  private

  def create_provider_accounts
    create_table :recording_studio_billing_provider_accounts, id: :uuid do |t|
      recording_reference t, :billing_admin
      t.string :key, null: false
      t.string :provider, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_provider_accounts
    add_check_constraint :recording_studio_billing_provider_accounts,
                         "provider ~ '^[a-z][a-z0-9_]*$'",
                         name: "rs_billing_provider_accounts_provider_format"
  end

  def create_markets
    create_table :recording_studio_billing_markets, id: :uuid do |t|
      recording_reference t, :provider_account
      t.string :key, null: false
      t.string :country_code, null: false
      t.string :currency_code, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_markets
    add_iso_code_constraints :recording_studio_billing_markets
  end

  def create_products
    create_table :recording_studio_billing_products, id: :uuid do |t|
      recording_reference t, :provider_account
      t.string :key, null: false
      t.string :kind, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_products
    add_check_constraint :recording_studio_billing_products,
                         "kind IN ('subscription', 'one_time')",
                         name: "rs_billing_products_kind"
  end

  def create_billing_options
    create_table :recording_studio_billing_billing_options, id: :uuid do |t|
      recording_reference t, :product
      t.string :key, null: false
      t.string :kind, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_billing_options
    add_check_constraint :recording_studio_billing_billing_options,
                         "kind IN ('recurring', 'usage')",
                         name: "rs_billing_options_kind"
  end

  def create_prices
    create_table :recording_studio_billing_prices, id: :uuid do |t|
      recording_reference t, :billing_option
      recording_reference t, :market
      t.string :key, null: false
      t.string :currency_code, null: false
      t.integer :currency_exponent, null: false
      t.bigint :amount_minor, null: false
      t.string :pricing_model, null: false
      t.integer :package_size
      t.integer :version, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_price_constraints :recording_studio_billing_prices
    add_index :recording_studio_billing_prices,
              %i[billing_option_recording_id market_recording_id currency_code version],
              unique: true,
              where: "state IN ('draft', 'published')",
              name: "idx_rs_billing_active_prices"
  end

  def create_overage_prices
    create_table :recording_studio_billing_overage_prices, id: :uuid do |t|
      recording_reference t, :billing_option
      recording_reference t, :market
      recording_reference t, :usage_unit
      t.string :key, null: false
      t.string :currency_code, null: false
      t.integer :currency_exponent, null: false
      t.bigint :amount_minor, null: false
      t.string :pricing_model, null: false
      t.integer :package_size
      t.integer :version, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_price_constraints :recording_studio_billing_overage_prices
    add_index :recording_studio_billing_overage_prices,
              %i[billing_option_recording_id market_recording_id usage_unit_recording_id currency_code version],
              unique: true,
              where: "state IN ('draft', 'published')",
              name: "idx_rs_billing_active_overage_prices"
  end

  def create_features
    create_table :recording_studio_billing_features, id: :uuid do |t|
      recording_reference t, :product
      t.string :key, null: false
      t.string :kind, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_features
    add_check_constraint :recording_studio_billing_features,
                         "kind IN ('boolean', 'quantity')",
                         name: "rs_billing_features_kind"
  end

  def create_feature_overrides
    create_table :recording_studio_billing_feature_overrides, id: :uuid do |t|
      recording_reference t, :account
      recording_reference t, :feature
      t.string :key, null: false
      t.jsonb :value, null: false, default: {}
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_feature_overrides
  end

  def create_product_rules
    create_table :recording_studio_billing_product_rules, id: :uuid do |t|
      recording_reference t, :product
      t.string :key, null: false
      t.string :rule_type, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_product_rules
  end

  def create_plan_updates
    create_table :recording_studio_billing_plan_updates, id: :uuid do |t|
      recording_reference t, :billing_option
      t.string :key, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_plan_updates
  end

  def create_usage_units
    create_table :recording_studio_billing_usage_units, id: :uuid do |t|
      recording_reference t, :provider_account
      t.string :key, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_usage_units
  end

  def create_meters
    create_table :recording_studio_billing_meters, id: :uuid do |t|
      recording_reference t, :usage_unit
      t.string :key, null: false
      t.string :aggregation, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_meters
    add_check_constraint :recording_studio_billing_meters,
                         "aggregation IN ('sum', 'count', 'last_value')",
                         name: "rs_billing_meters_aggregation"
  end

  def create_rate_cards
    create_table :recording_studio_billing_rate_cards, id: :uuid do |t|
      recording_reference t, :provider_account
      t.string :key, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_rate_cards
  end

  def create_rates
    create_table :recording_studio_billing_rates, id: :uuid do |t|
      recording_reference t, :rate_card
      recording_reference t, :usage_unit
      t.string :key, null: false
      t.bigint :amount_minor, null: false
      t.string :currency_code, null: false
      t.integer :currency_exponent, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_money_constraints :recording_studio_billing_rates
  end

  def create_cost_cards
    create_table :recording_studio_billing_cost_cards, id: :uuid do |t|
      recording_reference t, :provider_account
      t.string :key, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_state_constraint :recording_studio_billing_cost_cards
  end

  def create_cost_rates
    create_table :recording_studio_billing_cost_rates, id: :uuid do |t|
      recording_reference t, :cost_card
      recording_reference t, :usage_unit
      t.string :key, null: false
      t.bigint :amount_minor, null: false
      t.string :currency_code, null: false
      t.integer :currency_exponent, null: false
      t.string :state, null: false, default: "draft"
      t.timestamps
    end
    add_money_constraints :recording_studio_billing_cost_rates
  end

  def recording_reference(table, name)
    table.references :"#{name}_recording", type: :uuid, null: false, foreign_key: { to_table: RECORDINGS }
  end

  def add_state_constraint(table)
    add_check_constraint table, "state IN (#{STATES.map { |state| "'#{state}'" }.join(', ')})",
                         name: "#{table}_state"
  end

  def add_iso_code_constraints(table)
    add_check_constraint table, "country_code ~ '^[A-Z]{2}$'", name: "#{table}_country_code"
    add_check_constraint table, "currency_code ~ '^[A-Z]{3}$'", name: "#{table}_currency_code"
  end

  def add_money_constraints(table)
    add_state_constraint table
    add_check_constraint table, "amount_minor >= 0", name: "#{table}_amount_minor"
    add_check_constraint table, "currency_code ~ '^[A-Z]{3}$'", name: "#{table}_currency_code"
    add_check_constraint table, "currency_exponent BETWEEN 0 AND 3", name: "#{table}_currency_exponent"
  end

  def add_price_constraints(table)
    add_money_constraints table
    add_check_constraint table, "pricing_model IN ('flat', 'per_unit', 'package')",
                         name: "#{table}_pricing_model"
    add_check_constraint table,
                         "(pricing_model = 'package' AND package_size IS NOT NULL AND package_size > 0) OR " \
                         "(pricing_model IN ('flat', 'per_unit') AND package_size IS NULL)",
                         name: "#{table}_package_size"
    add_check_constraint table, "version >= 1", name: "#{table}_version"
  end
end
