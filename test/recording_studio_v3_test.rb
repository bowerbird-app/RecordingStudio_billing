# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

# rubocop:disable Metrics/BlockLength
class RecordingStudioV3Test < ActiveSupport::TestCase
  self.use_transactional_tests = false

  COMMERCIAL_RECORDABLES = [
    RecordingStudioBilling::CostRate,
    RecordingStudioBilling::CostCard,
    RecordingStudioBilling::Rate,
    RecordingStudioBilling::RateCard,
    RecordingStudioBilling::Meter,
    RecordingStudioBilling::UsageUnit,
    RecordingStudioBilling::PlanUpdate,
    RecordingStudioBilling::ProductRule,
    RecordingStudioBilling::FeatureOverride,
    RecordingStudioBilling::Feature,
    RecordingStudioBilling::OveragePrice,
    RecordingStudioBilling::Price,
    RecordingStudioBilling::BillingOption,
    RecordingStudioBilling::Product,
    RecordingStudioBilling::Market,
    RecordingStudioBilling::ProviderAccount,
    RecordingStudioBilling::Account,
    RecordingStudioBilling::BillingAdmin
  ].freeze

  setup { clear_billing_test_data! }
  teardown { clear_billing_test_data! }

  test "billing roots and capability-owned children validate" do
    assert RecordingStudio.validate_recordable_declarations!
    assert_equal %w[AdminRoot Workspace], RecordingStudio.root_recordable_types.sort
    assert_equal ["Workspace"], RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::Account)
    assert_equal ["AdminRoot"], RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::BillingAdmin)
    assert RecordingStudio.capability_enabled?(:billing, for: Workspace)
    assert RecordingStudio.capability_enabled?(:billing_admin, for: AdminRoot)
  end

  test "V1 product, feature, and meter vocabularies are exact" do
    assert_equal %w[plan addon credit_pack service], RecordingStudioBilling::Product::KINDS
    assert_equal %w[boolean limit allowance variant], RecordingStudioBilling::Feature::TYPES
    assert_equal %w[sum count maximum latest], RecordingStudioBilling::Meter::AGGREGATIONS

    assert_not_includes RecordingStudioBilling::Meter::AGGREGATIONS, "distinct_count"
    assert_not_includes RecordingStudioBilling::BillingOption::PRICING_MODELS, "graduated"
    assert_not_includes RecordingStudioBilling::BillingOption::PRICING_MODELS, "volume"
    assert_not_includes RecordingStudioBilling::BillingOption::PRICING_MODELS, "stairstep"
  end

  test "commercial recordables declare the configuration tree" do
    direct_billing_admin_children = [
      RecordingStudioBilling::ProviderAccount,
      RecordingStudioBilling::Market,
      RecordingStudioBilling::Product,
      RecordingStudioBilling::ProductRule,
      RecordingStudioBilling::PlanUpdate,
      RecordingStudioBilling::UsageUnit,
      RecordingStudioBilling::Meter,
      RecordingStudioBilling::RateCard,
      RecordingStudioBilling::CostCard
    ]

    direct_billing_admin_children.each do |recordable|
      assert_equal ["RecordingStudioBilling::BillingAdmin"],
                   RecordingStudio.allowed_parent_types_for(recordable),
                   "#{recordable.name} must be a direct BillingAdmin child"
    end

    assert_equal ["RecordingStudioBilling::Product"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::BillingOption)
    assert_equal ["RecordingStudioBilling::Product"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::Feature)
    assert_equal ["RecordingStudioBilling::BillingOption"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::Price)
    assert_equal ["RecordingStudioBilling::BillingOption"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::OveragePrice)
    assert_equal ["RecordingStudioBilling::RateCard"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::Rate)
    assert_equal ["RecordingStudioBilling::CostCard"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::CostRate)
    assert_equal ["RecordingStudioBilling::Account"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::FeatureOverride)
  end

  test "workspace gets one root-owned billing account" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Workspace")))
    account = RecordingStudioBilling.ensure_account(root_recording: root_recording, name: unique_name("Account"))
    recording = RecordingStudio::Recording.find_by!(recordable: account)

    assert_equal root_recording, account.root_recording
    assert_equal root_recording, recording.parent_recording
    assert_equal root_recording, recording.root_recording
  end

  test "admin root gets one root-owned billing administration child" do
    root_recording = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Administration")))
    billing_admin = RecordingStudioBilling.ensure_billing_admin(
      root_recording: root_recording,
      key: unique_name("billing")
    )
    recording = RecordingStudio::Recording.find_by!(recordable: billing_admin)

    assert_equal root_recording, billing_admin.root_recording
    assert_equal root_recording, recording.parent_recording
    assert_equal root_recording, recording.root_recording
  end

  test "billing children cannot be recorded under the wrong root type" do
    admin_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Administration")))
    account = RecordingStudioBilling::Account.new(name: unique_name("Account"))

    error = assert_raises(RecordingStudio::InvalidParent) { record_child(account, admin_root) }

    assert_equal "RecordingStudioBilling::Account cannot be recorded under AdminRoot", error.message
  end

  test "ensure_account normalizes descendants and serializes concurrent creation" do
    workspace = Workspace.create!(name: unique_name("Workspace"))
    root_recording = RecordingStudio.root_recording_for(workspace)
    account = RecordingStudioBilling.ensure_account(root_recording: root_recording, name: "First account")
    account_recording = RecordingStudio::Recording.find_by!(recordable: account)

    assert_equal account, RecordingStudioBilling.ensure_account(root_recording: account_recording, name: "Ignored name")
    assert_raises(ActiveRecord::RecordNotUnique) do
      record_child(
        RecordingStudioBilling::Account.new(root_recording: root_recording, name: "Duplicate account"),
        root_recording
      )
    end

    concurrent_root = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Concurrent workspace")))
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          results << RecordingStudioBilling.ensure_account(root_recording: concurrent_root, name: "Concurrent account")
        end
      rescue StandardError => e
        results << e
      end
      # rubocop:enable Metrics/BlockLength
    end
    2.times { start << true }
    threads.each(&:join)

    accounts = 2.times.map { results.pop }
    assert_empty accounts.grep(Exception)
    assert_equal 1, accounts.map(&:id).uniq.count
    assert_equal 1, RecordingStudioBilling::Account.where(root_recording: concurrent_root).count
  end

  # rubocop:disable Metrics/BlockLength
  test "root ownership survives revisions and ensure services return current snapshots" do
    workspace_root = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Workspace")))
    admin_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Administration")))
    historical_account = RecordingStudioBilling.ensure_account(
      root_recording: workspace_root,
      name: "Original account"
    )
    historical_admin = RecordingStudioBilling.ensure_billing_admin(
      root_recording: admin_root,
      key: unique_name("billing")
    )
    account_recording = historical_account.recording
    admin_recording = historical_admin.recording

    workspace_root.revise(account_recording) { |revision| revision.name = "Revised account" }
    admin_root.revise(admin_recording) { |revision| revision.key = unique_name("revised_billing") }

    current_account = account_recording.reload.recordable
    current_admin = admin_recording.reload.recordable
    assert_equal current_account, RecordingStudioBilling.ensure_account(
      root_recording: workspace_root,
      name: "Ignored"
    )
    assert_equal current_admin, RecordingStudioBilling.ensure_billing_admin(
      root_recording: admin_root,
      key: "ignored"
    )
    assert_equal workspace_root.id, historical_account.reload.root_recording_id
    assert_equal workspace_root.id, current_account.root_recording_id
    assert_equal admin_root.id, historical_admin.reload.root_recording_id
    assert_equal admin_root.id, current_admin.root_recording_id
    assert_equal 2, RecordingStudioBilling::Account.where(root_recording_id: workspace_root.id).count
    assert_equal 2, RecordingStudioBilling::BillingAdmin.where(root_recording_id: admin_root.id).count
  end
  # rubocop:enable Metrics/BlockLength

  # rubocop:disable Metrics/BlockLength
  test "V1 billing models validate the corrected contract and price versioning" do
    admin_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Administration")))
    billing_admin = RecordingStudioBilling.ensure_billing_admin(root_recording: admin_root, key: unique_name("billing"))
    billing_admin_recording = RecordingStudio::Recording.find_by!(recordable: billing_admin)
    provider_recording = record_child(
      RecordingStudioBilling::ProviderAccount.new(
        billing_admin_recording: billing_admin_recording,
        key: "primary_provider",
        adapter_key: "stripe",
        name: "Primary Stripe account",
        environment: "production",
        configuration: { "public_account_id" => "acct_public" },
        capabilities: %w[checkout subscriptions],
        supported_markets: ["US"],
        supported_currencies: ["USD"]
      ),
      admin_root,
      billing_admin_recording
    )
    market_recording = record_child(
      RecordingStudioBilling::Market.new(
        provider_account_recording: provider_recording,
        key: "us_market",
        country_codes: %w[US CA],
        allowed_currency_codes: %w[USD CAD],
        priority: 10,
        specificity: 2,
        fallback: false,
        ppa_policy: "standard",
        rounding_policy: "half_up",
        tax_presentation_policy: "exclusive",
        verification_policy: "none"
      ),
      admin_root,
      billing_admin_recording
    )
    product_recording = record_child(
      RecordingStudioBilling::Product.new(
        provider_account_recording: provider_recording,
        key: "studio",
        kind: "plan"
      ),
      admin_root,
      billing_admin_recording
    )
    option_recording = record_child(
      RecordingStudioBilling::BillingOption.new(
        product_recording: product_recording,
        key: "monthly",
        recurrence: "recurring",
        interval: "month",
        interval_count: 1,
        quantity_mode: "adjustable",
        minimum_quantity: 1,
        maximum_quantity: 10,
        default_quantity: 1,
        pricing_model: "flat",
        collection_method: "automatic",
        payment_terms_days: 0,
        trial_days: 14,
        proration_policy: "prorate",
        lifecycle_policy: "immediate",
        checkout_policy: "allowed",
        tax_policy: "exclusive"
      ),
      admin_root,
      product_recording
    )

    price = RecordingStudioBilling::Price.new(
      billing_option_recording: option_recording,
      market_recording: market_recording,
      key: "monthly_usd_v1",
      amount_minor: 0,
      currency_code: "USD",
      currency_exponent: 2,
      pricing_model: "flat",
      version: 1,
      scope: "standard"
    )
    assert_predicate price, :valid?
    record_child(price, admin_root, option_recording)

    invalid_version = price.dup
    invalid_version.key = "monthly_usd_invalid"
    invalid_version.version = 0
    assert_not_predicate invalid_version, :valid?
    assert_includes invalid_version.errors[:version], "must be greater than or equal to 1"

    direct_publication = price.dup
    direct_publication.key = "monthly_usd_v2"
    direct_publication.version = 2
    direct_publication.state = "published"
    assert_not_predicate direct_publication, :valid?
    assert_includes direct_publication.errors[:state], "may only change through an authorized commercial publication"

    invalid_product = RecordingStudioBilling::Product.new(
      provider_account_recording: provider_recording,
      key: "invalid_product",
      kind: "subscription"
    )
    assert_not_predicate invalid_product, :valid?
    assert_includes invalid_product.errors[:kind], "is not included in the list"

    invalid_market = RecordingStudioBilling::Market.new(
      provider_account_recording: provider_recording,
      key: "invalid_market",
      country_codes: ["usa"],
      allowed_currency_codes: ["usd"],
      priority: 0,
      specificity: 0,
      ppa_policy: "standard",
      rounding_policy: "half_up",
      tax_presentation_policy: "exclusive",
      verification_policy: "none"
    )
    assert_not_predicate invalid_market, :valid?
    assert_includes invalid_market.errors[:country_codes], "must be an array of ISO 3166-1 alpha-2 country codes"
    assert_includes invalid_market.errors[:allowed_currency_codes], "must be an array of ISO 4217 currency codes"

    invalid_meter = RecordingStudioBilling::Meter.new(
      usage_unit_recording: provider_recording,
      key: "distinct_meter",
      aggregation: "distinct_count"
    )
    assert_not_predicate invalid_meter, :valid?
    assert_includes invalid_meter.errors[:aggregation], "is not included in the list"

    invalid_price = price.dup
    invalid_price.key = "invalid_package"
    invalid_price.pricing_model = "package"
    invalid_price.package_size = 0
    assert_not_predicate invalid_price, :valid?
    assert_includes invalid_price.errors[:package_size], "must be a positive integer for package prices"
  end

  test "billing options reject unsupported tier pricing and rates never carry customer money" do
    billing_option = RecordingStudioBilling::BillingOption.new(
      key: "graduated",
      recurrence: "recurring",
      interval: "month",
      interval_count: 1,
      quantity_mode: "fixed",
      pricing_model: "graduated",
      collection_method: "automatic",
      payment_terms_days: 0,
      trial_days: 0,
      proration_policy: "none",
      lifecycle_policy: "immediate",
      checkout_policy: "allowed",
      tax_policy: "exclusive"
    )
    assert_not_predicate billing_option, :valid?
    assert_includes billing_option.errors[:pricing_model], "is not included in the list"

    rate = RecordingStudioBilling::Rate.new(
      key: "bytes_to_gigabytes",
      conversion_numerator: 1,
      conversion_denominator: 1_073_741_824
    )
    rate.valid?
    assert_empty rate.errors[:base]
    assert_not_respond_to rate, :amount_minor
    assert_not_respond_to rate, :currency_code

    provider = RecordingStudioBilling::ProviderAccount.new(
      key: "unsafe_provider",
      adapter_key: "stripe",
      name: "Unsafe account",
      environment: "production",
      configuration: { "api_key" => "must-not-be-stored" },
      capabilities: [],
      supported_markets: [],
      supported_currencies: []
    )
    assert_not_predicate provider, :valid?
    assert_includes provider.errors[:configuration], "must not contain credentials or secrets"
  end

  test "price identity constraints defer uniqueness to current Recording revisions" do
    indexes = ActiveRecord::Base.connection.indexes(:recording_studio_billing_prices)

    assert_not(indexes.any? { |index| index.name == "recording_studio_billing_prices_key" })
    assert_not(indexes.any? { |index| index.name == "recording_studio_billing_prices_historical_version" })
    assert_not(indexes.any? { |index| index.name == "recording_studio_billing_prices_published" })

    default_quantity = ActiveRecord::Base.connection.columns(
      :recording_studio_billing_billing_options
    ).find { |column| column.name == "default_quantity" }
    assert_equal 1, default_quantity.default.to_i
    assert_not default_quantity.null

    foreign_keys = ActiveRecord::Base.connection.foreign_keys(
      :recording_studio_billing_commercial_manifests
    )
    assert(foreign_keys.any? { |foreign_key| foreign_key.options[:name] == "fk_rs_billing_manifests_root" })
  end

  test "root ownership uniqueness is enforced on current Recording pointers" do
    connection = ActiveRecord::Base.connection
    account_root_index = connection.indexes(:recording_studio_billing_accounts).find do |index|
      index.name == "idx_rs_billing_account_root_history"
    end
    admin_root_index = connection.indexes(:recording_studio_billing_billing_admins).find do |index|
      index.name == "idx_rs_billing_admin_root_history"
    end
    recording_indexes = connection.indexes(:recording_studio_recordings)
    current_account_index = recording_indexes.find do |index|
      index.name == "idx_rs_billing_one_account_per_root"
    end
    current_admin_index = recording_indexes.find do |index|
      index.name == "idx_rs_billing_one_admin_per_root"
    end

    assert account_root_index
    assert admin_root_index
    refute_predicate account_root_index, :unique
    refute_predicate admin_root_index, :unique
    assert_predicate current_account_index, :unique
    assert_predicate current_admin_index, :unique
    assert_includes current_account_index.where, "RecordingStudioBilling::Account"
    assert_includes current_admin_index.where, "RecordingStudioBilling::BillingAdmin"
    assert_equal :sql, Rails.application.config.active_record.schema_format
  end
  # rubocop:enable Metrics/BlockLength

  private

  def clear_billing_test_data!
    connection = ActiveRecord::Base.connection
    tables = COMMERCIAL_RECORDABLES.map(&:table_name).map { |table| connection.quote_table_name(table) }.join(", ")
    connection.execute("TRUNCATE TABLE #{tables} RESTART IDENTITY CASCADE")
    RecordingStudioRootSwitchable::Selection.delete_all if defined?(RecordingStudioRootSwitchable::Selection)
    RecordingStudio::Event.unscoped.delete_all
    RecordingStudio::Recording.unscoped.delete_all
    Workspace.delete_all
    AdminRoot.delete_all
  end

  def record_child(recordable, root_recording, parent_recording = root_recording)
    RecordingStudio.record!(
      action: "created",
      recordable: recordable,
      root_recording: root_recording,
      parent_recording: parent_recording
    ).recording
  end

  def unique_name(prefix)
    "#{prefix} #{SecureRandom.hex(4)}"
  end
end
