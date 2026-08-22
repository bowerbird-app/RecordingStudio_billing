# frozen_string_literal: true

require_relative "../test_helper"
require "devise/test/integration_helpers"

class BillingAdminDashboardTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  parallelize(workers: 1)

  include Devise::Test::IntegrationHelpers

  HIGH_SIGNAL_SCREENS = %w[
    billing_products billing_prices billing_manifests
    billing_invoices billing_payments billing_financial_commands
    billing_subscriptions billing_plan_updates billing_reconciliation_issues
  ].freeze

  HUB_SECTIONS = %w[billing_commercial billing_financial billing_operations].freeze

  setup do
    acquire_database_lock!
    load Rails.root.join("db/seeds.rb").to_s
    @user = User.find_by!(email: "admin@admin.com")
    @admin_root = RecordingStudio.root_recording_for(AdminRoot.find_by!(name: "Billing Administration"))
    Current.actor = nil
    RecordingStudio::RootSwitchable::Current.device_key = nil
    sign_in @user
    select_admin_root
  end

  teardown { release_database_lock! }

  test "admin hubs enable inventory screens and hide account billing operations on the site root" do
    context = RecordingStudioAdmin::Context.new

    HUB_SECTIONS.each do |key|
      assert RecordingStudioAdmin.section_enabled?(key:, recording: @admin_root, context:), key
    end
    refute RecordingStudioAdmin.section_enabled?(
      key: "billing_account_operations", recording: @admin_root, context:
    )

    site_screens = RecordingStudioBilling::ADMIN_OPERATION_AREAS.keys.map(&:to_s) - %w[billing_feature_overrides]
    (HUB_SECTIONS + site_screens).each do |key|
      assert RecordingStudioAdmin.screen_enabled?(key:, recording: @admin_root, context:), key
    end
    refute RecordingStudioAdmin.screen_enabled?(
      key: "billing_feature_overrides", recording: @admin_root, context:
    )
  end

  test "dummy admin dashboards show hub widgets and seeded inventory rows" do
    get "/admin"
    assert_response :success
    assert_admin_shell
    assert_includes response.body, "Products and pricing"
    assert_includes response.body, "Products"
    assert_includes response.body, "Prices"
    assert_includes response.body, "Published manifests"
    refute_includes response.body, "View products and pricing"
    refute_includes response.body, "Table data"
    refute_includes response.body, "Sign out"

    HIGH_SIGNAL_SCREENS.first(3).each do |screen_key|
      widget_key = RecordingStudioBilling::BillingAdminHubs.widget_key_for(screen_key)
      get "/admin/sections/billing_commercial/widgets/#{widget_key}"
      assert_response :success, widget_key
      assert_operator seeded_row_count_for(screen_key), :>, 0
      assert_includes response.body, seeded_row_label_for(screen_key)
      assert_includes response.body, "/admin/screens/#{screen_key}"
    end

    {
      "billing_financial" => HIGH_SIGNAL_SCREENS[3, 3],
      "billing_operations" => HIGH_SIGNAL_SCREENS[6, 3]
    }.each do |section_key, screen_keys|
      get "/admin/sections/#{section_key}"
      assert_response :success, section_key
      assert_admin_shell
      section_body = response.body
      screen_keys.each do |screen_key|
        widget_key = RecordingStudioBilling::BillingAdminHubs.widget_key_for(screen_key)
        assert_includes section_body, RecordingStudioAdmin.widget_for(widget_key).title
        get "/admin/sections/#{section_key}/widgets/#{widget_key}"
        assert_response :success, widget_key
        assert_includes response.body, seeded_row_label_for(screen_key)
      end
    end
  end

  test "hub and inventory screens return tables with seeded rows" do
    (HUB_SECTIONS + RecordingStudioBilling::ADMIN_OPERATION_AREAS.keys.map(&:to_s) - %w[billing_feature_overrides]).each do |key|
      get "/admin/screens/#{key}"
      assert_response :success, key
      assert_admin_shell
      refute_includes response.body, "Table data"
      assert_includes response.body, "screen-table"

      get "/admin/screens/#{key}/table"
      assert_response :success, "#{key} table"
      assert_includes response.body, expected_table_title(key)
      next unless HIGH_SIGNAL_SCREENS.include?(key) || HUB_SECTIONS.include?(key)

      assert_includes response.body, seeded_row_label_for(key)
    end
  end

  test "admin discovery lists billing inventory and not account billing operations" do
    get "/admin/sections"
    assert_response :success
    assert_admin_shell
    assert_includes response.body, "Products and pricing"
    assert_includes response.body, "Financial records"
    assert_includes response.body, "Billing operations"
    refute_includes response.body, "Account billing operations"

    get "/admin/sections/billing_account_operations"
    assert_response :not_found

    get "/admin/sections", params: { q: "billing" }
    assert_response :success
    refute_includes response.body, "Account billing operations"
    HIGH_SIGNAL_SCREENS.each do |key|
      assert_includes response.body, "/admin/screens/#{key}"
    end
  end

  private

  def assert_admin_shell
    assert_includes response.body, 'data-recording-studio-default-layout="true"'
    assert_includes response.body, 'data-theme="rounded"'
    refute_includes response.body, "recording_studio_root_switch_dropdown"
    refute_includes response.body, "Sign out"
  end

  def expected_table_title(key)
    RecordingStudioBilling::BillingAdminHubs::HUB_TABLES.dig(key, :title) ||
      RecordingStudioBilling::ADMIN_OPERATION_AREAS.fetch(key.to_sym).fetch(:title)
  end

  def seeded_row_label_for(key)
    case key
    when "billing_commercial", "billing_manifests"
      RecordingStudioBilling::CommercialManifest.order(created_at: :desc).first.manifest_digest.first(12)
    when "billing_financial", "billing_financial_commands"
      RecordingStudioBilling::FinancialCommand.order(created_at: :desc).first.command_type
    when "billing_operations", "billing_reconciliation_issues"
      RecordingStudioBilling::ReconciliationIssue.order(created_at: :desc).first.kind
    when "billing_products"
      RecordingStudioBilling::Product.with_current_recording.order(created_at: :desc).first.key
    when "billing_prices"
      RecordingStudioBilling::Price.with_current_recording.order(created_at: :desc).first.key
    when "billing_invoices"
      RecordingStudioBilling::Invoice.order(created_at: :desc).first.currency_code
    when "billing_payments"
      RecordingStudioBilling::Payment.order(created_at: :desc).first.currency_code
    when "billing_subscriptions"
      RecordingStudioBilling::Subscription.with_current_recording.order(created_at: :desc).first.identifier
    when "billing_plan_updates"
      RecordingStudioBilling::PlanUpdate.with_current_recording.order(created_at: :desc).first.key
    else
      raise "no seeded label for #{key}"
    end
  end

  def seeded_row_count_for(key)
    spec = RecordingStudioBilling::BillingAdminHubs::WIDGET_SPECS.find { |entry| entry.fetch(:screen) == key }
    RecordingStudioBilling::BillingAdminHubs.widget_scope(spec).count
  end

  def select_admin_root
    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces", root_switch: { root_recording_id: @admin_root.id, return_to: "/" }
    }
    assert_response :redirect
  end

  def acquire_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
  end

  def release_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
  end
end
