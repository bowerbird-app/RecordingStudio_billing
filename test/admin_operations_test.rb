# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"
require "devise/test/integration_helpers"

class AdminOperationsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    BillingTestDatabaseCleanup.clear!
    @user = User.create!(email: "admin-operation-#{SecureRandom.hex(4)}@example.test", password: "Password1!",
                         password_confirmation: "Password1!")
    @price, @billing_admin_recording = draft_price
    @plan_update, @plan_update_run = plan_update_fixture
    @financial_command = reconciliation_command
    sign_in @user
  end

  teardown { BillingTestDatabaseCleanup.clear! }

  test "publication endpoint rejects a signed-in actor without site-admin access" do
    RecordingStudioAccessible.stub(:authorized?, false) do
      post "/billing/admin/operations/publish_price/#{@price.id}"
    end

    assert_response :forbidden
  end

  test "publication endpoint authorizes the registered site action and calls CommercialPublisher" do
    calls = []

    RecordingStudioAccessible.stub(:authorized?, true) do
      RecordingStudioBilling::CommercialPublisher.stub(:publish!, ->(**attributes) { calls << attributes }) do
        post "/billing/admin/operations/publish_price/#{@price.id}"
      end
    end

    assert_equal 1, calls.size
    assert_equal [@price.recording.id], calls.sole.fetch(:price_recording_ids)
    assert_equal @user, calls.sole.fetch(:actor)
    assert_redirected_to "/admin/screens/billing_prices"
  end

  test "every mutation endpoint rejects an unauthenticated request" do
    sign_out @user

    operation_paths.each do |path|
      post path
      assert_response :redirect, path
    end
  end

  test "every mutation endpoint forbids an actor without site-admin access" do
    RecordingStudioAccessible.stub(:authorized?, false) do
      operation_paths.each do |path|
        post path
        assert_response :forbidden, path
      end
    end
  end

  test "plan update preview confirm and apply delegate to one run" do
    calls = []

    with_site_admin do
      RecordingStudioBilling::ApplyPlanUpdate.stub(:call, lambda { |**attributes|
        calls << attributes
        @plan_update_run
      }) do
        post "/billing/admin/operations/preview_plan_update/#{@plan_update.id}"
        assert_nil flash[:alert], flash[:alert]
        post "/billing/admin/operations/confirm_plan_update/#{@plan_update_run.id}"
        assert_nil flash[:alert], flash[:alert]
        post "/billing/admin/operations/apply_plan_update/#{@plan_update_run.id}"
        assert_nil flash[:alert], flash[:alert]
      end
    end

    assert_equal([@plan_update, @plan_update_run, @plan_update_run], calls.map do |attributes|
      attributes.fetch(:plan_update, attributes[:run])
    end)
    assert_equal([@billing_admin_recording.root_recording.id] * 3, calls.map do |attributes|
      attributes.fetch(:root_recording).id
    end)
    assert_equal @plan_update_run.idempotency_key, calls.second.fetch(:idempotency_key)
    assert_equal @plan_update_run.idempotency_key, calls.third.fetch(:idempotency_key)
  end

  test "reconciliation endpoint delegates only to ReconcileProviderCommand" do
    calls = []

    with_site_admin do
      RecordingStudioBilling::ReconcileProviderCommand.stub(:call, ->(**attributes) { calls << attributes }) do
        post "/billing/admin/operations/reconcile_command/#{@financial_command.id}"
      end
    end

    assert_equal [{ command: @financial_command }], calls
    assert_redirected_to "/admin/screens/billing_financial_commands"
  end

  test "operation failure redirects safely without mutating the price" do
    original_amount = @price.amount_minor

    with_site_admin do
      RecordingStudioBilling::CommercialPublisher.stub(:publish!, lambda { |**|
        raise ArgumentError, "publication rejected"
      }) do
        post "/billing/admin/operations/publish_price/#{@price.id}"
      end
    end

    assert_redirected_to "/admin/screens/billing_prices"
    assert_equal original_amount, @price.reload.amount_minor
  end

  test "plan update and reconciliation failures do not mutate protected records" do
    original_run_state = @plan_update_run.state
    original_command_state = @financial_command.state

    with_site_admin do
      RecordingStudioBilling::ApplyPlanUpdate.stub(:call, ->(**) { raise ArgumentError, "plan update rejected" }) do
        post "/billing/admin/operations/preview_plan_update/#{@plan_update.id}"
        assert_redirected_to "/admin/screens/billing_plan_updates"
        post "/billing/admin/operations/confirm_plan_update/#{@plan_update_run.id}"
        assert_redirected_to "/admin/screens/billing_plan_update_runs"
        post "/billing/admin/operations/apply_plan_update/#{@plan_update_run.id}"
        assert_redirected_to "/admin/screens/billing_plan_update_runs"
      end
      RecordingStudioBilling::ReconcileProviderCommand.stub(:call, lambda { |**|
        raise ArgumentError, "reconciliation rejected"
      }) do
        post "/billing/admin/operations/reconcile_command/#{@financial_command.id}"
      end
    end

    assert_redirected_to "/admin/screens/billing_financial_commands"
    assert_equal original_run_state, @plan_update_run.reload.state
    assert_equal original_command_state, @financial_command.reload.state
  end

  private

  def draft_price
    root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Admin #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: root, key: "billing")
    provider = record_child(RecordingStudioBilling::ProviderAccount.new(
                              billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}", adapter_key: "fake", name: "Fake",
                              environment: "test", configuration: {}, capabilities: [], supported_markets: ["US"], supported_currencies: ["USD"]
                            ), root, admin.recording)
    market = record_child(RecordingStudioBilling::Market.new(
                            provider_account_recording: provider, key: "market_#{SecureRandom.hex(4)}", country_codes: ["US"], country_groups: {},
                            regional_country_codes: [], global_fallback: false, allowed_currency_codes: ["USD"], default_currency_code: "USD",
                            priority: 1, specificity: 1, ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive", verification_policy: "none"
                          ), root, admin.recording)
    product = record_child(
      RecordingStudioBilling::Product.new(provider_account_recording: provider, key: "product_#{SecureRandom.hex(4)}",
                                          kind: "service", feature_values: {}), root, admin.recording
    )
    option = record_child(RecordingStudioBilling::BillingOption.new(
                            product_recording: product, key: "option_#{SecureRandom.hex(4)}", recurrence: "one_time", quantity_mode: "fixed", default_quantity: 1,
                            pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0, trial_days: 0, proration_policy: "none",
                            lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"
                          ), root, product)
    price = record_child(RecordingStudioBilling::Price.new(
                           billing_option_recording: option, market_recording: market, key: "price_#{SecureRandom.hex(4)}", amount_minor: 1_000,
                           currency_code: "USD", currency_exponent: 2, pricing_model: "flat", version: 1, scope: "default"
                         ), root, option).recordable
    [price, admin.recording]
  end

  def plan_update_fixture
    root = @billing_admin_recording.root_recording
    option = @price.billing_option_recording
    manifest = used_manifest(root)
    update = record_child(RecordingStudioBilling::PlanUpdate.new(
                            billing_option_recording: option, key: "update_#{SecureRandom.hex(4)}", allowance_policy: "preserve", execution_state: "draft",
                            replacement_manifest_digest: manifest.manifest_digest, replacement_configuration: { "audience" => { "root_recording_ids" => [SecureRandom.uuid] } }
                          ), root, @billing_admin_recording).recordable
    run = update.runs.create!(idempotency_key: "preview:#{update.id}", request_fingerprint: "a" * 64,
                              state: "awaiting_confirmation", preview: {}, confirmation: {}, reconciliation: {})
    [update, run]
  end

  def reconciliation_command
    customer_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Customer #{SecureRandom.hex(4)}"))
    account = RecordingStudioBilling.ensure_account(root_recording: customer_root, name: "Billing")
    provider = @price.billing_option_recording.recordable.product_recording.recordable.provider_account_recording
    RecordingStudioBilling.create_financial_command(
      root_recording: customer_root, account_recording: account.recording, command_type: "reconcile_test",
      local_idempotency_key: SecureRandom.uuid, provider_account_recording: provider, provider_adapter_key: "fake", request: { amount_minor: 1 }
    ).command
  end

  def used_manifest(root)
    canonical_data = { "fixture" => true }
    snapshots = [{ "fixture" => true }]
    references = { "fixture" => { "fixture" => true } }
    envelope = { "schema_version" => "v1", "resolver_version" => "v1", "root_recording_id" => root.id,
                 "canonical_data" => canonical_data, "recording_snapshots" => snapshots, "snapshot_references" => references }
    RecordingStudioBilling::CommercialManifest.create!(root_recording_id: root.id, schema_version: "v1",
                                                       resolver_version: "v1", canonical_data:, recording_snapshots: snapshots, snapshot_references: references, manifest_digest: RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope), used_at: Time.current)
  end

  def with_site_admin(&)
    RecordingStudioAccessible.stub(:authorized?, true, &)
  end

  def operation_paths
    [
      "/billing/admin/operations/publish_price/#{@price.id}",
      "/billing/admin/operations/preview_plan_update/#{@plan_update.id}",
      "/billing/admin/operations/confirm_plan_update/#{@plan_update_run.id}",
      "/billing/admin/operations/apply_plan_update/#{@plan_update_run.id}",
      "/billing/admin/operations/reconcile_command/#{@financial_command.id}"
    ]
  end

  def record_child(recordable, root, parent)
    RecordingStudio::Recording.unscoped.find(
      RecordingStudio.record!(action: "created", recordable:, root_recording: root,
                              parent_recording: parent).recording.id
    )
  end
end
