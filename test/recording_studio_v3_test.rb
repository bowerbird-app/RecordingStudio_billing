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

  test "commercial recordables declare the configuration tree" do
    assert_includes RecordingStudio.configuration.recordable_types, "RecordingStudioBilling::CostRate"
    assert_equal ["RecordingStudioBilling::BillingAdmin"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::ProviderAccount)
    assert_equal ["RecordingStudioBilling::ProviderAccount"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::Market)
    assert_equal ["RecordingStudioBilling::Product"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::BillingOption)
    assert_equal ["RecordingStudioBilling::BillingOption"],
                 RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::Price)
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
      RecordingStudioBilling::Account.create!(root_recording: root_recording, name: "Duplicate account")
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
  test "commercial model validations and active price scope use stable recording ids" do
    admin_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Administration")))
    billing_admin = RecordingStudioBilling.ensure_billing_admin(root_recording: admin_root, key: unique_name("billing"))
    billing_admin_recording = RecordingStudio::Recording.find_by!(recordable: billing_admin)
    provider_recording = record_child(
      RecordingStudioBilling::ProviderAccount.new(
        billing_admin_recording: billing_admin_recording,
        key: "primary_provider",
        provider: "stripe"
      ),
      admin_root,
      billing_admin_recording
    )
    market_recording = record_child(
      RecordingStudioBilling::Market.new(
        provider_account_recording: provider_recording,
        key: "us_market",
        country_code: "US",
        currency_code: "USD"
      ),
      admin_root,
      provider_recording
    )
    product_recording = record_child(
      RecordingStudioBilling::Product.new(
        provider_account_recording: provider_recording,
        key: "studio",
        kind: "subscription"
      ),
      admin_root,
      provider_recording
    )
    option_recording = record_child(
      RecordingStudioBilling::BillingOption.new(
        product_recording: product_recording,
        key: "monthly",
        kind: "recurring"
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
      version: 1
    )
    assert_predicate price, :valid?
    record_child(price, admin_root, option_recording)

    duplicate_price = price.dup
    duplicate_price.key = "duplicate_monthly_usd_v1"
    assert_raises(ActiveRecord::RecordNotUnique) { record_child(duplicate_price, admin_root, option_recording) }

    invalid_product = RecordingStudioBilling::Product.new(
      provider_account_recording: provider_recording,
      key: "invalid_product",
      kind: "metered"
    )
    assert_not_predicate invalid_product, :valid?
    assert_includes invalid_product.errors[:kind], "is not included in the list"

    invalid_market = RecordingStudioBilling::Market.new(
      provider_account_recording: provider_recording,
      key: "invalid_market",
      country_code: "usa",
      currency_code: "usd"
    )
    assert_not_predicate invalid_market, :valid?
    assert_includes invalid_market.errors[:country_code], "is invalid"
    assert_includes invalid_market.errors[:currency_code], "is invalid"

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
  # rubocop:enable Metrics/BlockLength

  private

  def clear_billing_test_data!
    COMMERCIAL_RECORDABLES.each(&:delete_all)
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
