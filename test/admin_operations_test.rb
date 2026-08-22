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
    acquire_database_lock!
    BillingTestDatabaseCleanup.clear!
    @user = User.create!(email: "admin-operation-#{SecureRandom.hex(4)}@example.test", password: "Password1!",
                         password_confirmation: "Password1!")
    @price, @billing_admin_recording = draft_price
    @plan_update, @plan_update_run = plan_update_fixture
    @financial_command = reconciliation_command
    sign_in @user
  rescue StandardError
    BillingTestDatabaseCleanup.clear!
    release_database_lock!
    raise
  end

  teardown do
    BillingTestDatabaseCleanup.clear! if @database_lock_held
  ensure
    release_database_lock!
  end

  test "publication endpoint rejects a signed-in actor without site-admin access" do
    post "/billing/admin/operations/publish_price/#{@price.id}"

    assert_response :forbidden
    refute RecordingStudioAccessible.authorized?(
      actor: @user, recording: site_admin_recording, role: :view
    )
  end

  test "RecordingStudioAdmin denies an actor without the registered admin action role" do
    grant_view_access!(site_admin_recording)

    post "/billing/admin/operations/publish_price/#{@price.id}"

    assert_response :forbidden
    assert RecordingStudioAccessible.authorized?(
      actor: @user, recording: site_admin_recording, role: :view
    )
    refute RecordingStudioAccessible.authorized?(
      actor: @user, recording: site_admin_recording, role: :admin
    )
  end

  test "an AdminRoot A actor cannot operate on an AdminRoot B record" do
    grant_admin_access!(site_admin_recording)
    foreign_price, foreign_billing_admin = draft_price(admin_name: "Foreign Admin #{SecureRandom.hex(4)}")

    post "/billing/admin/operations/publish_price/#{foreign_price.id}"

    assert_response :forbidden
    assert_equal foreign_billing_admin.root_recording, foreign_price.recording.root_recording
    refute_equal site_admin_recording, foreign_billing_admin.root_recording
  end

  test "publication endpoint authorizes the registered site action and calls CommercialPublisher" do
    calls = []
    grant_admin_access!(site_admin_recording)

    RecordingStudioBilling::CommercialPublisher.stub(:publish!, ->(**attributes) { calls << attributes }) do
      post "/billing/admin/operations/publish_price/#{@price.id}"
    end

    assert_equal 1, calls.size
    assert_equal [@price.recording.id], calls.sole.fetch(:price_recording_ids)
    assert_equal @user, calls.sole.fetch(:actor)
    assert_redirected_to "/admin/screens/billing_prices"
  end

  test "admin action audit identifies the AdminRoot, resource, action, and actor" do
    audit_events = []

    with_site_admin do
      RecordingStudioBilling::CommercialPublisher.stub(:publish!, ->(**) {}) do
        ActiveSupport::Notifications.subscribed(
          ->(*arguments) { audit_events << ActiveSupport::Notifications::Event.new(*arguments).payload },
          RecordingStudioAdmin::AdminActionAudit::NOTIFICATION_NAME
        ) do
          post "/billing/admin/operations/publish_price/#{@price.id}"
        end
      end
    end

    event = audit_events.find { |payload| payload[:outcome] == "performed" }
    assert_equal @billing_admin_recording.root_recording, event.fetch(:access_recording)
    assert_equal @price, event.fetch(:record)
    assert_equal @user, event.fetch(:actor)
    assert_equal "billing_prices", event.fetch(:resource_key)
    assert_equal "publish", event.fetch(:action_key)
  end

  test "every mutation endpoint rejects an unauthenticated request" do
    sign_out @user

    operation_paths.each do |path|
      post path
      assert_response :redirect, path
    end
  end

  test "every mutation endpoint forbids an actor without site-admin access" do
    operation_paths.each do |path|
      post path
      assert_response :forbidden, path
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

  test "commercial draft revision and retirement use Recording Studio and CommercialPublisher" do
    provider_key = "provider_#{SecureRandom.hex(4)}"
    product_key = "product_#{SecureRandom.hex(4)}"
    option_key = "option_#{SecureRandom.hex(4)}"
    price_key = "price_#{SecureRandom.hex(4)}"
    billing_admin = @billing_admin_recording
    assert_predicate billing_admin, :persisted?
    provider_attributes = provider_account_attributes.merge(billing_admin_recording_id: billing_admin.id, key: provider_key)

    with_site_admin do
      post "/billing/admin/operations/create_draft_provider_account", params: {
        parent_recording_id: billing_admin.id,
        attributes: provider_attributes
      }
      assert_redirected_to "/admin/screens/billing_provider_accounts"
      provider = RecordingStudioBilling::ProviderAccount.with_current_recording.find_by!(key: provider_key)
      post "/billing/admin/operations/revise_provider_account/#{provider.id}", params: { attributes: { name: "Revised provider" } }
      provider = RecordingStudioBilling::ProviderAccount.with_current_recording.find_by!(key: provider_key)
      assert_equal "Revised provider", provider.name
      provider_recording = recording_for(provider)

      post "/billing/admin/operations/create_draft_product", params: {
        parent_recording_id: billing_admin.id,
        attributes: { key: product_key, kind: "service", provider_account_recording_id: provider_recording.id }
      }
      product = RecordingStudioBilling::Product.with_current_recording.find_by!(key: product_key)
      post "/billing/admin/operations/revise_product/#{product.id}", params: { attributes: { kind: "addon" } }
      product = RecordingStudioBilling::Product.with_current_recording.find_by!(key: product_key)
      assert_equal "addon", product.kind
      product_recording = recording_for(product)

      post "/billing/admin/operations/create_draft_billing_option", params: {
        parent_recording_id: product_recording.id,
        attributes: billing_option_attributes(key: option_key, product_recording: product_recording)
      }
      option = RecordingStudioBilling::BillingOption.with_current_recording.find_by!(key: option_key)
      post "/billing/admin/operations/revise_billing_option/#{option.id}", params: { attributes: { checkout_policy: "required" } }
      option = RecordingStudioBilling::BillingOption.with_current_recording.find_by!(key: option_key)
      assert_equal "required", option.checkout_policy
      option_recording = recording_for(option)

      post "/billing/admin/operations/create_draft_price", params: {
        parent_recording_id: option_recording.id,
        attributes: price_attributes(key: price_key, billing_option_recording: option_recording)
      }
      price = RecordingStudioBilling::Price.with_current_recording.find_by!(key: price_key)
      post "/billing/admin/operations/revise_price/#{price.id}", params: { attributes: { amount_minor: 1_200 } }
      price = RecordingStudioBilling::Price.with_current_recording.find_by!(key: price_key)
      assert_equal 1_200, price.amount_minor

      [price, option, product, provider].each do |record|
        post "/billing/admin/operations/retire_#{commercial_operation_name_for(record)}/#{record.id}"
        assert_redirected_to "/admin/screens/#{resource_key_for(record)}"
        assert_equal "retired", record.class.with_current_recording.find_by!(key: record.key).state
      end
    end
  end

  test "commercial draft creation requires an explicit allowed parent in the current AdminRoot" do
    original_count = RecordingStudioBilling::Product.count
    assert_predicate @billing_admin_recording, :persisted?

    sign_in @user
    with_site_admin do
      post "/billing/admin/operations/create_draft_product", params: { attributes: { key: "missing_parent", kind: "service" } }
      assert_response :not_found
      assert_predicate controller.current_user, :present?
      sign_in @user
      post "/billing/admin/operations/create_draft_product", params: {
        parent_recording_id: @price.billing_option_recording.id,
        attributes: { key: "wrong_parent", kind: "service", provider_account_recording_id: catalogue_provider_recording.id }
      }
      assert_response :not_found
    end

    assert_equal original_count, RecordingStudioBilling::Product.count
    foreign_price, foreign_admin = draft_price(admin_name: "Foreign Admin #{SecureRandom.hex(4)}")
    sign_in @user
    grant_admin_access!(site_admin_recording)
    post "/billing/admin/operations/create_draft_provider_account", params: {
      parent_recording_id: foreign_admin.id, attributes: provider_account_attributes.merge(key: "foreign_provider")
    }
    assert_response :forbidden
    assert_equal foreign_admin.root_recording, foreign_price.recording.root_recording
  end

  test "product create screen authorizes billing_products create like other admin actions" do
    context = product_create_admin_context

    refute RecordingStudioBilling::BillingAdminProductNew.create_allowed?(context)

    grant_view_access!(site_admin_recording)
    refute RecordingStudioBilling::BillingAdminProductNew.create_allowed?(context)
  end

  test "a site admin can use the product create screen action" do
    with_site_admin do
      assert RecordingStudioBilling::BillingAdminProductNew.create_allowed?(product_create_admin_context)
    end
  end

  test "Account-root feature override administration uses FeatureOverrideReviser with audit attribution" do
    override, account_root = feature_override_fixture
    audit_events = []
    grant_admin_access!(account_root)
    select_root(account_root)

    with_site_admin do
      ActiveSupport::Notifications.subscribed(
        ->(*arguments) { audit_events << ActiveSupport::Notifications::Event.new(*arguments).payload },
        RecordingStudioAdmin::AdminActionAudit::NOTIFICATION_NAME
      ) do
        post "/billing/admin/operations/revise_feature_override/#{override.id}", params: { attributes: { value: true } }
      end
      current = RecordingStudioBilling::FeatureOverride.with_current_recording.find_by!(key: override.key)
      assert_equal true, current.value
      post "/billing/admin/operations/supersede_feature_override/#{current.id}", params: { attributes: { value: false } }
      current = RecordingStudioBilling::FeatureOverride.with_current_recording.find_by!(key: override.key)
      assert_equal false, current.value
      post "/billing/admin/operations/revoke_feature_override/#{current.id}"
    end

    current = RecordingStudioBilling::FeatureOverride.with_current_recording.find_by!(key: override.key)
    assert_equal "retired", current.state
    event = audit_events.find { |payload| payload[:outcome] == "performed" }
    assert_equal account_root, event.fetch(:access_recording)
    assert_equal @user, event.fetch(:actor)
    assert_equal "billing_feature_overrides", event.fetch(:resource_key)
    assert_equal "revise", event.fetch(:action_key)
  end

  test "feature override operations deny a selected foreign Account root without disclosure" do
    override, account_root = feature_override_fixture
    foreign_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Foreign #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: foreign_root, name: "Billing")
    grant_admin_access!(account_root)
    grant_view_access!(foreign_root)
    select_root(foreign_root)

    with_site_admin do
      post "/billing/admin/operations/revise_feature_override/#{override.id}", params: { attributes: { value: true } }
    end

    assert_response :forbidden
    assert_equal false, RecordingStudioBilling::FeatureOverride.with_current_recording.find_by!(key: override.key).value
    assert_not_equal account_root, foreign_root
  end

  test "feature override reviser failure creates no revision" do
    override, account_root = feature_override_fixture
    grant_admin_access!(account_root)
    select_root(account_root)
    original_recording = recording_for(override)
    original_event_count = RecordingStudio::Event.where(recording: original_recording).count

    with_site_admin do
      RecordingStudioBilling::FeatureOverrideReviser.stub(:call, ->(**) { raise ArgumentError, "override rejected" }) do
        post "/billing/admin/operations/revise_feature_override/#{override.id}", params: { attributes: { value: true } }
      end
    end

    assert_redirected_to "/admin/screens/billing_feature_overrides"
    assert_equal original_recording.id, recording_for(override.reload).id
    assert_equal original_event_count, RecordingStudio::Event.where(recording: original_recording).count
  end

  test "refund and adjustment actions create intents through their services with audit actor attribution" do
    payment, invoice = financial_projection_fixture
    refund_calls = []
    adjustment_calls = []

    with_site_admin do
      RecordingStudioBilling::CreateRefundIntent.stub(:call, ->(**attributes) { refund_calls << attributes }) do
        post "/billing/admin/operations/create_refund_intent/#{payment.id}", params: {
          attributes: { local_idempotency_key: "refund-admin", amount_minor: 25, reason: "customer request",
                        line_allocation: { payment: payment.id } }
        }
      end
      RecordingStudioBilling::CreateAdjustmentIntent.stub(:call, ->(**attributes) { adjustment_calls << attributes }) do
        post "/billing/admin/operations/create_adjustment_intent/#{invoice.id}", params: {
          attributes: { local_idempotency_key: "adjustment-admin", kind: "credit", amount_minor: 25,
                        reason: "billing correction", affected_reference: { invoice: invoice.id } }
        }
      end
    end

    assert_equal @user.id.to_s, refund_calls.sole.fetch(:actor_reference)
    assert_equal @user.id.to_s, adjustment_calls.sole.fetch(:actor_reference)
    assert_equal payment.root_recording, refund_calls.sole.fetch(:root_recording)
    assert_equal invoice.root_recording, adjustment_calls.sole.fetch(:root_recording)
    assert_equal 0, RecordingStudioBilling::Refund.count
    assert_equal 0, RecordingStudioBilling::FinancialAdjustment.count
  end

  test "new service failures redirect without mutating protected commercial or financial projections" do
    payment, invoice = financial_projection_fixture

    with_site_admin do
      RecordingStudioBilling::CommercialPublisher.stub(:retire!, ->(**) { raise ArgumentError, "retirement rejected" }) do
        post "/billing/admin/operations/retire_price/#{@price.id}"
      end
      assert_redirected_to "/admin/screens/billing_prices"
      RecordingStudioBilling::CreateRefundIntent.stub(:call, ->(**) { raise ArgumentError, "refund rejected" }) do
        post "/billing/admin/operations/create_refund_intent/#{payment.id}", params: { attributes: refund_request_attributes }
      end
      assert_redirected_to "/admin/screens/billing_payments"
      RecordingStudioBilling::CreateAdjustmentIntent.stub(:call, ->(**) { raise ArgumentError, "adjustment rejected" }) do
        post "/billing/admin/operations/create_adjustment_intent/#{invoice.id}", params: { attributes: adjustment_request_attributes }
      end
    end

    assert_redirected_to "/admin/screens/billing_invoices"
    assert_equal "draft", @price.reload.state
    assert_equal 0, RecordingStudioBilling::Refund.count
    assert_equal 0, RecordingStudioBilling::FinancialAdjustment.count
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

  def draft_price(admin_name: "Billing Administration")
    admin = if admin_name == "Billing Administration"
              AdminRoot.find_or_create_by!(name: admin_name)
            else
              AdminRoot.create!(name: admin_name)
            end
    root = RecordingStudio.root_recording_for(admin)
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
                           currency_code: "USD", currency_exponent: 2, pricing_model: "flat", version: 1, scope: "market"
                         ), root, option).recordable
    billing_admin_recording = RecordingStudio::Recording.unscoped.find_by!(
      root_recording_id: root.id, recordable_type: "RecordingStudioBilling::BillingAdmin"
    )
    [price, billing_admin_recording]
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

  def feature_override_fixture
    feature = record_child(RecordingStudioBilling::Feature.new(
                             product_recording: @price.billing_option_recording.recordable.product_recording,
                             key: "feature_#{SecureRandom.hex(4)}", kind: "boolean"
                           ), @billing_admin_recording.root_recording, @price.billing_option_recording.recordable.product_recording)
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Override #{SecureRandom.hex(4)}"))
    account = RecordingStudioBilling.ensure_account(root_recording: root, name: "Billing")
    override = record_child(RecordingStudioBilling::FeatureOverride.new(
                              account_recording: account.recording, feature_recording: feature, key: "override_#{SecureRandom.hex(4)}", value: false
                            ), root, account.recording).recordable
    [override, root]
  end

  def financial_projection_fixture
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Finance #{SecureRandom.hex(4)}"))
    account = RecordingStudioBilling.ensure_account(root_recording: root, name: "Billing")
    provider = @price.billing_option_recording.recordable.product_recording.recordable.provider_account_recording
    command = RecordingStudioBilling.create_financial_command(
      root_recording: root, account_recording: account.recording, command_type: "capture_funds",
      local_idempotency_key: SecureRandom.uuid, provider_account_recording: provider, provider_adapter_key: "fake", request: { amount_minor: 100 }
    ).command
    now = Time.current
    payment = RecordingStudioBilling::Payment.create!(root_recording: root, account_recording: account.recording, financial_command: command,
                                                      provider_reference: "payment-#{SecureRandom.uuid}", currency_code: "USD", amount_minor: 100,
                                                      state: "captured", safe_snapshot: {}, recorded_at: now)
    invoice = RecordingStudioBilling::Invoice.create!(root_recording: root, account_recording: account.recording, financial_command: command,
                                                      provider_reference: "invoice-#{SecureRandom.uuid}", currency_code: "USD", total_minor: 100,
                                                      state: "issued", safe_snapshot: {}, issued_at: now)
    [payment, invoice]
  end

  def provider_account_attributes
    { key: "provider_#{SecureRandom.hex(4)}", adapter_key: "fake", name: "Fake", environment: "test",
      supported_markets: ["US"], supported_currencies: ["USD"], billing_admin_recording_id: catalogue_billing_admin.id }
  end

  def billing_option_attributes(key:, product_recording:)
    { key:, product_recording_id: product_recording.id, recurrence: "one_time", quantity_mode: "fixed", default_quantity: 1,
      pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0, trial_days: 0, proration_policy: "none",
      lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive" }
  end

  def price_attributes(key:, billing_option_recording:)
    { key:, billing_option_recording_id: billing_option_recording.id, market_recording_id: @price.market_recording_id, amount_minor: 1_000,
      currency_code: "USD", currency_exponent: 2, pricing_model: "flat", version: 1, scope: "market" }
  end

  def catalogue_billing_admin
    RecordingStudio::Recording.unscoped.find_by!(root_recording_id: @price.recording.root_recording_id,
                                                 recordable_type: "RecordingStudioBilling::BillingAdmin")
  end

  def catalogue_provider_recording
    RecordingStudio::Recording.unscoped.find_by!(root_recording_id: @price.recording.root_recording_id,
                                                 recordable_type: "RecordingStudioBilling::ProviderAccount")
  end

  def resource_key_for(record)
    {
      "ProviderAccount" => "billing_provider_accounts",
      "Product" => "billing_products",
      "BillingOption" => "billing_options",
      "Price" => "billing_prices"
    }.fetch(record.class.name.demodulize)
  end

  def commercial_operation_name_for(record)
    {
      "ProviderAccount" => "provider_account",
      "Product" => "product",
      "BillingOption" => "billing_option",
      "Price" => "price"
    }.fetch(record.class.name.demodulize)
  end

  def recording_for(recordable)
    RecordingStudio::Recording.unscoped.find_by!(recordable_type: recordable.class.name, recordable_id: recordable.id)
  end

  def refund_request_attributes
    { local_idempotency_key: SecureRandom.uuid, amount_minor: 25, reason: "customer request", line_allocation: {} }
  end

  def adjustment_request_attributes
    { local_idempotency_key: SecureRandom.uuid, kind: "credit", amount_minor: 25, reason: "billing correction", affected_reference: { invoice: "invoice" } }
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

  def with_site_admin
    grant_admin_access!(site_admin_recording)
    yield
  end

  def site_admin_recording
    @billing_admin_recording.root_recording
  end

  def product_create_admin_context
    recording = site_admin_recording
    actor = @user
    controller = Object.new
    controller.define_singleton_method(:current_root_recording) { recording }
    context = RecordingStudioAdmin::Context.new(current_actor: actor, controller: controller)
    context.define_singleton_method(:access_recording) { recording }
    context
  end

  def grant_admin_access!(recording, actor: @user)
    return if RecordingStudioAccessible.authorized?(actor:, recording:, role: :admin)

    result = RecordingStudioAccessible.bootstrap_owner_access!(recording:, actor:)
    return if result.success?

    result = RecordingStudioAccessible.grant_access(
      recording:, actor:, role: :admin, manager_actor: actor
    )
    raise result.error unless result.success?
  end

  def grant_view_access!(recording, actor: @user)
    manager = User.create!(
      email: "access-manager-#{SecureRandom.hex(4)}@example.test",
      password: "Password1!",
      password_confirmation: "Password1!"
    )
    owner = RecordingStudioAccessible.bootstrap_owner_access!(recording:, actor: manager)
    raise owner.error unless owner.success?

    result = RecordingStudioAccessible.grant_access(
      recording:, actor:, role: :view, manager_actor: manager
    )
    raise result.error unless result.success?
  end

  def select_root(root)
    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces", root_switch: { root_recording_id: root.id, return_to: "/" }
    }
    assert_response :redirect
    get "/"
    assert_response :success
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

  def acquire_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
    @database_lock_held = true
  end

  def release_database_lock!
    return unless @database_lock_held

    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
    @database_lock_held = false
  end

  def record_child(recordable, root, parent)
    RecordingStudio::Recording.unscoped.find(
      RecordingStudio.record!(action: "created", recordable:, root_recording: root,
                              parent_recording: parent).recording.id
    )
  end
end
