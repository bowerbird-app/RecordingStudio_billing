# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength
class CorrectV1BillingContract < ActiveRecord::Migration[8.1]
  COMMERCIAL_TABLES = %i[
    recording_studio_billing_provider_accounts
    recording_studio_billing_markets
    recording_studio_billing_products
    recording_studio_billing_billing_options
    recording_studio_billing_prices
    recording_studio_billing_overage_prices
    recording_studio_billing_features
    recording_studio_billing_feature_overrides
    recording_studio_billing_product_rules
    recording_studio_billing_plan_updates
    recording_studio_billing_usage_units
    recording_studio_billing_meters
    recording_studio_billing_rate_cards
    recording_studio_billing_rates
    recording_studio_billing_cost_cards
    recording_studio_billing_cost_rates
  ].freeze

  def up
    correct_provider_accounts
    correct_markets
    correct_kinds
    correct_billing_options
    correct_prices
    correct_rates
    correct_recording_hierarchy
  end
  # rubocop:enable Metrics/ClassLength

  def down
    raise ActiveRecord::IrreversibleMigration,
          "The V1 billing contract removes incompatible columns and constraints."
  end

  private

  # The migration is intentionally explicit so each destructive V1 correction
  # and its upgrade data transformation is auditable.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def correct_provider_accounts
    rename_column :recording_studio_billing_provider_accounts, :provider, :adapter_key
    add_column :recording_studio_billing_provider_accounts, :name, :string
    execute <<~SQL.squish
      UPDATE recording_studio_billing_provider_accounts
      SET name = adapter_key
      WHERE name IS NULL
    SQL
    change_column_null :recording_studio_billing_provider_accounts, :name, false
    add_column :recording_studio_billing_provider_accounts, :environment, :string, null: false, default: "production"
    add_column :recording_studio_billing_provider_accounts, :active, :boolean, null: false, default: true
    add_column :recording_studio_billing_provider_accounts, :configuration, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_provider_accounts, :capabilities, :jsonb, null: false, default: []
    add_column :recording_studio_billing_provider_accounts, :supported_markets, :jsonb, null: false, default: []
    add_column :recording_studio_billing_provider_accounts, :supported_currencies, :jsonb, null: false, default: []
    add_column :recording_studio_billing_provider_accounts, :checkout_default, :boolean, null: false, default: false
  end

  def correct_markets
    table = :recording_studio_billing_markets
    # Add and populate the replacement fields before dropping the original
    # scalar values.  This migration is run against real, populated catalogues.
    add_column table, :country_codes, :jsonb, null: false, default: []
    add_column table, :allowed_currency_codes, :jsonb, null: false, default: []
    execute <<~SQL.squish
      UPDATE #{table}
      SET country_codes = jsonb_build_array(country_code),
          allowed_currency_codes = jsonb_build_array(currency_code)
      WHERE country_code IS NOT NULL AND currency_code IS NOT NULL
    SQL
    remove_check_constraint table, name: "recording_studio_billing_markets_country_code"
    remove_check_constraint table, name: "recording_studio_billing_markets_currency_code"
    remove_column table, :country_code
    remove_column table, :currency_code
    add_column table, :priority, :integer, null: false, default: 0
    add_column table, :specificity, :integer, null: false, default: 0
    add_column table, :fallback, :boolean, null: false, default: false
    add_column table, :ppa_policy, :string, null: false, default: "standard"
    add_column table, :rounding_policy, :string, null: false, default: "standard"
    add_column table, :tax_presentation_policy, :string, null: false, default: "exclusive"
    add_column table, :verification_policy, :string, null: false, default: "none"
    add_check_constraint table, "priority >= 0", name: "rs_billing_markets_priority"
    add_check_constraint table, "specificity >= 0", name: "rs_billing_markets_specificity"
  end

  def correct_kinds
    transform_or_fail!(:recording_studio_billing_products, :kind,
                       "subscription" => "plan", "one_time" => "service")
    transform_or_fail!(:recording_studio_billing_features, :kind,
                       "boolean" => "boolean", "quantity" => "limit")
    transform_or_fail!(:recording_studio_billing_meters, :aggregation,
                       "sum" => "sum", "count" => "count", "maximum" => "maximum",
                       "last_value" => "latest", "latest" => "latest")
    replace_check_constraint :recording_studio_billing_products, "rs_billing_products_kind",
                             "kind IN ('plan', 'addon', 'credit_pack', 'service')"
    replace_check_constraint :recording_studio_billing_features, "rs_billing_features_kind",
                             "kind IN ('boolean', 'limit', 'allowance', 'variant')"
    replace_check_constraint :recording_studio_billing_meters, "rs_billing_meters_aggregation",
                             "aggregation IN ('sum', 'count', 'maximum', 'latest')"
  end

  def correct_billing_options
    table = :recording_studio_billing_billing_options
    transform_or_fail!(table, :kind, "recurring" => "recurring", "usage" => "usage")
    add_column table, :recurrence, :string, null: false, default: "one_time"
    add_column table, :interval, :string
    add_column table, :interval_count, :integer
    add_column table, :quantity_mode, :string, null: false, default: "fixed"
    add_column table, :minimum_quantity, :integer
    add_column table, :maximum_quantity, :integer
    add_column table, :default_quantity, :integer, null: false, default: 1
    add_column table, :pricing_model, :string, null: false, default: "flat"
    add_column table, :collection_method, :string, null: false, default: "automatic"
    add_column table, :payment_terms_days, :integer, null: false, default: 0
    add_column table, :trial_days, :integer, null: false, default: 0
    add_column table, :proration_policy, :string, null: false, default: "none"
    add_column table, :lifecycle_policy, :string, null: false, default: "immediate"
    add_column table, :checkout_policy, :string, null: false, default: "allowed"
    add_column table, :tax_policy, :string, null: false, default: "exclusive"
    execute <<~SQL.squish
      UPDATE #{table}
      SET recurrence = CASE kind WHEN 'recurring' THEN 'recurring' ELSE 'one_time' END,
          interval = CASE kind WHEN 'recurring' THEN 'month' ELSE NULL END,
          interval_count = CASE kind WHEN 'recurring' THEN 1 ELSE NULL END,
          pricing_model = CASE kind WHEN 'usage' THEN 'per_unit' ELSE 'flat' END
    SQL
    remove_check_constraint table, name: "rs_billing_options_kind"
    remove_column table, :kind
    add_check_constraint table, "recurrence IN ('one_time', 'recurring')", name: "rs_billing_options_recurrence"
    add_check_constraint table, "interval IN ('day', 'week', 'month', 'year') OR interval IS NULL",
                         name: "rs_billing_options_interval"
    add_check_constraint table, "interval_count > 0 OR interval_count IS NULL",
                         name: "rs_billing_options_interval_count"
    add_check_constraint table, "quantity_mode IN ('fixed', 'adjustable')", name: "rs_billing_options_quantity_mode"
    add_check_constraint table, "minimum_quantity >= 0 OR minimum_quantity IS NULL",
                         name: "rs_billing_options_minimum_quantity"
    add_check_constraint table, "maximum_quantity > 0 OR maximum_quantity IS NULL",
                         name: "rs_billing_options_maximum_quantity"
    add_check_constraint table, "default_quantity > 0", name: "rs_billing_options_default_quantity"
    add_check_constraint table,
                         "minimum_quantity IS NULL OR maximum_quantity IS NULL OR minimum_quantity <= maximum_quantity",
                         name: "rs_billing_options_quantity_bounds"
    add_check_constraint table, "minimum_quantity IS NULL OR default_quantity >= minimum_quantity",
                         name: "rs_billing_options_default_minimum"
    add_check_constraint table, "maximum_quantity IS NULL OR default_quantity <= maximum_quantity",
                         name: "rs_billing_options_default_maximum"
    add_check_constraint table, "pricing_model IN ('flat', 'per_unit', 'package')",
                         name: "rs_billing_options_pricing_model"
    add_check_constraint table, "collection_method IN ('automatic', 'invoice')",
                         name: "rs_billing_options_collection_method"
    add_check_constraint table, "payment_terms_days >= 0", name: "rs_billing_options_payment_terms_days"
    add_check_constraint table, "trial_days >= 0", name: "rs_billing_options_trial_days"
    add_check_constraint table, "proration_policy IN ('none', 'prorate')", name: "rs_billing_options_proration_policy"
    add_check_constraint table, "lifecycle_policy IN ('immediate', 'scheduled')",
                         name: "rs_billing_options_lifecycle_policy"
    add_check_constraint table, "checkout_policy IN ('allowed', 'required', 'disabled')",
                         name: "rs_billing_options_checkout_policy"
    add_check_constraint table, "tax_policy IN ('exclusive', 'inclusive', 'automatic')",
                         name: "rs_billing_options_tax_policy"
  end

  def correct_prices
    correct_price_table :recording_studio_billing_prices,
                        %i[billing_option_recording_id scope market_recording_id currency_code]
    correct_price_table :recording_studio_billing_overage_prices,
                        %i[billing_option_recording_id scope market_recording_id usage_unit_recording_id currency_code]
  end

  def correct_price_table(table, identity_columns)
    active_index_name = if table == :recording_studio_billing_prices
                          "idx_rs_billing_active_prices"
                        else
                          "idx_rs_billing_active_overage_prices"
                        end
    remove_index table, name: active_index_name
    add_column table, :scope, :string, null: false, default: "default"
    add_index table, [*identity_columns, :version], unique: true, name: "#{table}_historical_version"
    add_index table, identity_columns, unique: true, where: "state = 'published'",
                                       name: "#{table}_published"
  end

  def correct_rates
    table = :recording_studio_billing_rates
    add_column table, :legacy_monetary_data, :jsonb, null: false, default: {}
    execute <<~SQL.squish
      UPDATE #{table}
      SET legacy_monetary_data = jsonb_build_object(
        'amount_minor', amount_minor, 'currency_code', currency_code, 'currency_exponent', currency_exponent
      )
    SQL
    %w[amount_minor currency_code currency_exponent].each do |column|
      remove_check_constraint table, name: "#{table}_#{column}"
      remove_column table, column
    end
    add_column table, :conversion_numerator, :bigint
    add_column table, :conversion_denominator, :bigint
    add_column table, :conversion_decimal, :decimal, precision: 30, scale: 12
    execute <<~SQL.squish
      UPDATE #{table}
      SET conversion_decimal = (legacy_monetary_data->>'amount_minor')::numeric
      WHERE (legacy_monetary_data->>'amount_minor')::numeric > 0
    SQL
    if select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM #{table}
      WHERE conversion_decimal IS NULL
    SQL
      raise ActiveRecord::MigrationError,
            "Cannot convert zero-valued legacy Rate records safely. Export or retire them, then rerun this migration."
    end
    add_check_constraint table, <<~SQL.squish, name: "rs_billing_rates_conversion"
      (conversion_numerator IS NOT NULL AND conversion_numerator > 0 AND
       conversion_denominator IS NOT NULL AND conversion_denominator > 0 AND conversion_decimal IS NULL) OR
      (conversion_numerator IS NULL AND conversion_denominator IS NULL AND
       conversion_decimal IS NOT NULL AND conversion_decimal > 0)
    SQL
  end

  # Semantic links (such as product_recording_id) deliberately remain untouched.
  # Only the Recording Studio parent is normalized to the static V1 tree.
  def correct_recording_hierarchy
    execute <<~SQL.squish
      UPDATE recording_studio_recordings AS child
      SET parent_recording_id = billing_admin_recording.id
      FROM recording_studio_billing_billing_admins AS billing_admin
      INNER JOIN recording_studio_recordings AS billing_admin_recording
        ON billing_admin_recording.recordable_type = 'RecordingStudioBilling::BillingAdmin'
        AND billing_admin_recording.recordable_id = billing_admin.id
      WHERE child.recordable_type IN (
        'RecordingStudioBilling::ProviderAccount',
        'RecordingStudioBilling::Market',
        'RecordingStudioBilling::Product',
        'RecordingStudioBilling::ProductRule',
        'RecordingStudioBilling::PlanUpdate',
        'RecordingStudioBilling::UsageUnit',
        'RecordingStudioBilling::Meter',
        'RecordingStudioBilling::RateCard',
        'RecordingStudioBilling::CostCard'
      )
        AND child.root_recording_id = billing_admin.root_recording_id
        AND child.parent_recording_id IS DISTINCT FROM billing_admin_recording.id
    SQL
  end

  def replace_check_constraint(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end

  def transform_or_fail!(table, column, mapping)
    values = select_values("SELECT DISTINCT #{column} FROM #{table}").compact
    unsupported = values - mapping.keys
    if unsupported.any?
      raise ActiveRecord::MigrationError,
            "#{table}.#{column} contains unsupported values: #{unsupported.join(', ')}. " \
            "Update or retire those records before running the V1 correction."
    end

    mapping.each do |from, to|
      execute "UPDATE #{table} SET #{column} = #{connection.quote(to)} WHERE #{column} = #{connection.quote(from)}"
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
end
