# frozen_string_literal: true

require_relative "../test_helper"
require "devise/test/integration_helpers"

class BillingAdminDashboardTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  parallelize(workers: 1)

  include Devise::Test::IntegrationHelpers

  HIGH_SIGNAL_SCREENS = %w[
    billing_products billing_plans billing_addons
    billing_prices billing_manifests
    billing_invoices billing_payments billing_financial_commands
    billing_subscriptions billing_plan_updates billing_reconciliation_issues
  ].freeze

  HUB_SECTIONS = %w[billing billing_commercial billing_financial billing_operations].freeze

  setup do
    acquire_database_lock!
    BillingTestDatabaseCleanup.clear!
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

    site_screens = RecordingStudioBilling::ADMIN_OPERATION_AREAS.keys.map(&:to_s) -
                   %w[billing_feature_overrides] +
                   RecordingStudioBilling::BillingAdminForms::KIND_SCREENS.keys
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
    assert_includes response.body, "Billing"
    assert_includes response.body, "Products"
    assert_includes response.body, "Plans"
    assert_includes response.body, "Add-ons"
    assert_select "a[href='/admin/screens/billing_products']", text: "Products"
    assert_select "a[href='/admin/screens/billing_plans']", text: "Plans"
    assert_select "a[href='/admin/screens/billing_addons']", text: "Add-ons"
    refute_includes response.body, "Table data"
    refute_includes response.body, "Sign out"
    assert_admin_access_avatars

    HIGH_SIGNAL_SCREENS.first(3).each do |screen_key|
      widget_key = RecordingStudioBilling::BillingAdminHubs.widget_key_for(screen_key)
      get "/admin/sections/billing/widgets/#{widget_key}"
      assert_response :success, widget_key
      assert_operator seeded_row_count_for(screen_key), :>, 0
      assert_includes response.body, seeded_row_label_for(screen_key)
      assert_includes response.body, "/admin/screens/#{screen_key}"
    end

    {
      "billing_commercial" => %w[billing_products billing_prices billing_manifests],
      "billing_financial" => %w[billing_invoices billing_payments billing_financial_commands],
      "billing_operations" => %w[billing_subscriptions billing_plan_updates billing_reconciliation_issues]
    }.each do |section_key, screen_keys|
      get "/admin/sections/#{section_key}"
      assert_response :success, section_key
      assert_admin_shell
      assert_admin_access_avatars
      section_body = response.body
      screen_keys.each do |screen_key|
        widget_key = RecordingStudioBilling::BillingAdminHubs.widget_key_for(screen_key)
        assert_includes section_body, RecordingStudioAdmin.widget_for(widget_key).title
        get "/admin/sections/#{section_key}/widgets/#{widget_key}"
        assert_response :success, widget_key
        assert_includes response.body, seeded_row_label_for(screen_key)
        next unless screen_key == "billing_financial_commands"

        assert_includes response.body, "subscription_change · "
        refute_includes response.body, 'flex-shrink-0 ml-2">requires_reconciliation'
      end
    end
  end

  test "billing admin shortcut redirects to the Billing hub" do
    get "/admin/billing"

    assert_redirected_to "/admin/sections/billing"
  end

  test "hub and inventory screens return tables with seeded rows" do
    inventory_keys = RecordingStudioBilling::ADMIN_OPERATION_AREAS.keys.map(&:to_s) -
                     %w[billing_feature_overrides] +
                     RecordingStudioBilling::BillingAdminForms::KIND_SCREENS.keys
    (HUB_SECTIONS + inventory_keys).each do |key|
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

  test "products inventory New opens the billing create-draft page" do
    billing_admin = billing_admin_recording
    get "/admin/screens/billing_products"
    assert_response :success
    assert_admin_shell
    assert_select "a[href*='/billing/admin/products/new'][href*='parent_recording_id=#{billing_admin.id}']", text: "New"
    refute_includes response.body, "[&>*]:rounded-none"
    get "/admin/screens/billing_products/table"
    assert_response :success
    product = RecordingStudioBilling::Product.with_current_recording.order(created_at: :desc).first
    assert_includes response.body, product.name
    assert_includes response.body, product.key

    get "/billing/admin/products/new", params: {
      parent_recording_id: billing_admin.id,
      return_to: "/admin/screens/billing_products"
    }
    assert_response :success
    assert_admin_shell
    assert_includes response.body, "New product"
    assert_select "form[action^='/billing/admin/operations/create_draft_product']"
    assert_select "input[name='parent_recording_id'][value='#{billing_admin.id}']"
    assert_select "input[name='attributes[name]']"
    assert_select "input[name='attributes[key]']"
    assert_select "select[name='attributes[kind]']"
    assert_select "select[name='attributes[provider_account_recording_id]']"
    refute_includes response.body, "Select an option"
    refute_includes response.body, "Sign out"
    refute_includes response.body, "recording_studio_root_switch_dropdown"
    assert_admin_access_avatars
  end

  test "catalogue New and Edit actions use billing engine pages" do
    billing_admin = billing_admin_recording
    plan = RecordingStudioBilling::Product.with_current_recording.find_by!(kind: "plan")
    addon = RecordingStudioBilling::Product.with_current_recording.find_by!(kind: "addon")
    option = RecordingStudioBilling::BillingOption.with_current_recording.order(created_at: :desc).first
    price = RecordingStudioBilling::Price.with_current_recording.order(created_at: :desc).first

    get "/admin/screens/billing_plans"
    assert_response :success
    assert_select "a[href*='/billing/admin/products/new'][href*='kind=plan']", text: "New"
    get "/admin/screens/billing_plans/table"
    assert_includes response.body, plan.name
    refute_includes response.body, addon.name

    get "/admin/screens/billing_addons"
    assert_response :success
    assert_select "a[href*='/billing/admin/products/new'][href*='kind=addon']", text: "New"
    get "/admin/screens/billing_addons/table"
    assert_includes response.body, addon.name
    refute_includes response.body, plan.name

    get "/billing/admin/products/new", params: {
      parent_recording_id: billing_admin.id,
      kind: "plan",
      return_to: "/admin/screens/billing_plans"
    }
    assert_response :success
    assert_includes response.body, "New plan"
    assert_select "input[type=hidden][name='attributes[kind]'][value=plan]"
    assert_select "select[name='attributes[kind]']", count: 0

    get "/billing/admin/products/new", params: {
      parent_recording_id: billing_admin.id,
      kind: "addon",
      return_to: "/admin/screens/billing_addons"
    }
    assert_response :success
    assert_includes response.body, "New add-on"
    assert_select "input[type=hidden][name='attributes[kind]'][value=addon]"

    get "/admin/screens/billing_options"
    assert_response :success
    assert_select "a[href*='/billing/admin/options/new']", text: "New"
    get "/billing/admin/options/new", params: { parent_recording_id: billing_admin.id }
    assert_response :success
    assert_select "form[action^='/billing/admin/operations/create_draft_billing_option']"
    assert_select "select[name='parent_recording_id'] option[value='#{plan.recording.id}']"

    get "/admin/screens/billing_prices"
    assert_response :success
    assert_select "a[href*='/billing/admin/prices/new']", text: "New"
    get "/billing/admin/prices/new", params: { parent_recording_id: billing_admin.id }
    assert_response :success
    assert_select "form[action^='/billing/admin/operations/create_draft_price']"
    assert_select "select[name='parent_recording_id'] option[value='#{option.recording.id}']"
    assert_select "select[name='attributes[market_recording_id]']"

    {
      "/billing/admin/products/#{plan.id}/edit" => ["revise_product", "attributes[name]", plan.name],
      "/billing/admin/options/#{option.id}/edit" => ["revise_billing_option", "attributes[name]", option.name],
      "/billing/admin/prices/#{price.id}/edit" => ["revise_price", "attributes[key]", price.key]
    }.each do |path, (operation, field_name, field_value)|
      get path
      assert_response :success, path
      assert_select "form[action*='#{operation}']"
      assert_select "input[name='#{field_name}'][value='#{field_value}']"
    end
  end

  test "catalogue tables expose Edit and destructive Retire actions" do
    {
      "billing_products" => RecordingStudioBilling::Product.with_current_recording.order(created_at: :desc).first,
      "billing_options" => RecordingStudioBilling::BillingOption.with_current_recording.order(created_at: :desc).first,
      "billing_prices" => RecordingStudioBilling::Price.with_current_recording.order(created_at: :desc).first
    }.each do |screen_key, record|
      get "/admin/screens/#{screen_key}/table"
      assert_response :success
      assert_select "a[href*='/billing/admin/'][href*='/#{record.id}/edit']", text: "Edit"
      assert_select "a[href*='/billing/admin/operations/retire_'][data-turbo-method=post]" do |links|
        assert(links.any? { |link| link.text.strip == "Retire" })
        assert(links.any? { |link| link["data-turbo-confirm"] == "Retire this from the catalogue?" })
      end
    end
  end

  test "new product GET authorizes against the scoped Admin root when the host resolver is silent" do
    original_resolver = RecordingStudioAdmin.configuration.access_recording_resolver
    RecordingStudioAdmin.configuration.access_recording_resolver = ->(_context) {}
    get "/billing/admin/products/new", params: { parent_recording_id: billing_admin_recording.id }
    assert_response :success
    assert_includes response.body, "New product"
  ensure
    RecordingStudioAdmin.configuration.access_recording_resolver = original_resolver
  end

  private

  def assert_admin_shell
    assert_includes response.body, 'data-recording-studio-default-layout="true"'
    assert_select "html[data-theme=rounded]"
    assert_select "body[data-theme=rounded]"
    refute_includes response.body, "recording_studio_root_switch_dropdown"
    refute_includes response.body, "Sign out"
  end

  def assert_admin_access_avatars
    refute_includes response.body, "+ Access"
    assert_includes response.body, "Manage access"
    assert_includes response.body, ">Ad<"
    assert_includes response.body, "/accesses"
  end

  def expected_table_title(key)
    RecordingStudioBilling::BillingAdminHubs::HUB_TABLES.dig(key, :title) ||
      RecordingStudioBilling::BillingAdminForms::KIND_SCREENS.dig(key, :title) ||
      RecordingStudioBilling::ADMIN_OPERATION_AREAS.fetch(key.to_sym).fetch(:title)
  end

  def seeded_row_label_for(key)
    case key
    when "billing", "billing_products"
      RecordingStudioBilling::Product.with_current_recording.order(created_at: :desc).first.name
    when "billing_commercial", "billing_manifests"
      RecordingStudioBilling::CommercialManifest.order(created_at: :desc).first.manifest_digest.first(12)
    when "billing_financial", "billing_financial_commands"
      RecordingStudioBilling::FinancialCommand.order(created_at: :desc).first.command_type
    when "billing_operations", "billing_reconciliation_issues"
      RecordingStudioBilling::ReconciliationIssue.order(created_at: :desc).first.kind
    when "billing_plans"
      RecordingStudioBilling::Product.with_current_recording.where(kind: "plan").order(created_at: :desc).first.name
    when "billing_addons"
      RecordingStudioBilling::Product.with_current_recording.where(kind: "addon").order(created_at: :desc).first.name
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

  def billing_admin_recording
    RecordingStudio::Recording.unscoped.find_by!(
      root_recording_id: @admin_root.id,
      parent_recording_id: @admin_root.id,
      recordable_type: "RecordingStudioBilling::BillingAdmin",
      trashed_at: nil
    )
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
