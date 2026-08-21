# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class ProjectsGateIntegrationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    host! "localhost"
    @previous_forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false
    acquire_database_lock!
    @user = User.create!(
      email: "projects-#{SecureRandom.hex(4)}@example.com",
      password: "Password1!",
      password_confirmation: "Password1!"
    )
    Current.actor = @user
    @workspace = Workspace.create!(name: "Projects Workspace #{SecureRandom.hex(4)}")
    @root = RecordingStudio.root_recording_for(@workspace)
    @free_plan_key = "projects_free_plan_#{SecureRandom.hex(4)}"
    seed_free_plan_and_bootstrap!
    grant_workspace_access!
    sign_in @user
  end

  teardown do
    Current.actor = nil
    RecordingStudio::RootSwitchable::Current.device_key = nil
    RecordingStudioBilling.configuration.default_free_plan_product_key = "demo_free_plan"
    ActionController::Base.allow_forgery_protection = @previous_forgery unless @previous_forgery.nil?
    cleanup_projects_fixtures!
  ensure
    release_database_lock!
  end

  test "projects page uses soft gate status and hard create enforcement" do
    assert_equal 0, Project.for_root(@root).count
    assert RecordingStudioBilling.gate_allowed?(root_recording: @root, gate_key: "demo_projects")

    get projects_path(root_recording_id: @root.id)
    assert_response :success
    assert_match(/Projects/, response.body)
    assert_match(/still add 2 of 2/, response.body)

    post projects_path(root_recording_id: @root.id), params: { project: { name: "First project" } }
    assert_redirected_to projects_path(root_recording_id: @root.id)
    follow_redirect!
    assert_match(/First project/, response.body)
    assert_equal 1, Project.for_root(@root).count

    post projects_path(root_recording_id: @root.id), params: { project: { name: "Second project" } }
    assert_redirected_to projects_path(root_recording_id: @root.id)
    follow_redirect!
    assert_equal 2, Project.for_root(@root).count

    get projects_path(root_recording_id: @root.id)
    assert_match(/limit reached/i, response.body)
    assert_match(/See plans/, response.body)

    post projects_path(root_recording_id: @root.id), params: { project: { name: "Blocked project" } }
    assert_redirected_to projects_path(root_recording_id: @root.id)
    follow_redirect!
    assert_match(/limit reached/i, response.body)
    assert_equal 2, Project.for_root(@root).count
    refute_match(/Blocked project/, response.body)
  end

  private

  def seed_free_plan_and_bootstrap!
    admin_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Admin #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: admin_root, key: "billing_#{SecureRandom.hex(4)}")
    provider = admin_root.record(RecordingStudioBilling::ProviderAccount, parent_recording: admin.recording) do |account|
      account.billing_admin_recording = admin.recording
      account.key = "provider_#{SecureRandom.hex(4)}"
      account.adapter_key = "fake"
      account.name = "Fake"
      account.environment = "test"
      account.configuration = {}
      account.capabilities = []
      account.supported_markets = ["US"]
      account.supported_currencies = ["USD"]
    end
    market = admin_root.record(RecordingStudioBilling::Market, parent_recording: admin.recording) do |row|
      row.provider_account_recording = provider
      row.key = "us_market_#{SecureRandom.hex(4)}"
      row.country_codes = ["US"]
      row.country_groups = {}
      row.regional_country_codes = []
      row.global_fallback = false
      row.allowed_currency_codes = ["USD"]
      row.default_currency_code = "USD"
      row.priority = 10
      row.specificity = 1
      row.ppa_policy = "standard"
      row.rounding_policy = "half_up"
      row.tax_presentation_policy = "exclusive"
      row.verification_policy = "requote"
    end
    product = admin_root.record(RecordingStudioBilling::Product, parent_recording: admin.recording) do |row|
      row.provider_account_recording = provider
      row.key = @free_plan_key
      row.kind = "plan"
      row.feature_values = { "demo_projects" => 2 }
    end
    option = admin_root.record(RecordingStudioBilling::BillingOption, parent_recording: product) do |row|
      row.product_recording = product
      row.key = "#{@free_plan_key}_option"
      row.recurrence = "recurring"
      row.interval = "month"
      row.interval_count = 1
      row.quantity_mode = "fixed"
      row.default_quantity = 1
      row.pricing_model = "flat"
      row.collection_method = "automatic"
      row.payment_terms_days = 0
      row.trial_days = 0
      row.proration_policy = "none"
      row.lifecycle_policy = "immediate"
      row.checkout_policy = "allowed"
      row.tax_policy = "exclusive"
      row.feature_values = { "demo_projects" => 2 }
    end
    admin_root.record(RecordingStudioBilling::Feature, parent_recording: product) do |row|
      row.product_recording = product
      row.key = "demo_projects"
      row.kind = "limit"
      row.definition = {}
    end
    price = admin_root.record(RecordingStudioBilling::Price, parent_recording: option) do |row|
      row.billing_option_recording = option
      row.market_recording = market
      row.key = "#{@free_plan_key}_us_price"
      row.amount_minor = 0
      row.currency_code = "USD"
      row.currency_exponent = 2
      row.pricing_model = "flat"
      row.version = 1
      row.scope = "market"
      row.feature_values = {}
    end
    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: admin_root,
      price_recording_ids: [price.id],
      actor: @user
    )
    RecordingStudioBilling.configuration.default_free_plan_product_key = @free_plan_key
    RecordingStudioBilling.ensure_account(root_recording: @root, name: "Projects account")
  end

  def grant_workspace_access!
    previous = RecordingStudioAccessible.configuration.access_management_authorizer
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }
    result = RecordingStudioAccessible.grant_access(
      recording: @root,
      actor: @user,
      role: "edit",
      manager_actor: @user
    )
    raise "could not grant workspace access: #{result.error}" unless result.success?
  ensure
    RecordingStudioAccessible.configuration.access_management_authorizer = previous if defined?(previous)
  end

  def cleanup_projects_fixtures!
    BillingTestDatabaseCleanup.clear!
  end

  def acquire_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
    @database_lock_held = true
  end

  def release_database_lock!
    return unless @database_lock_held

    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
    @database_lock_held = false
  end
end
