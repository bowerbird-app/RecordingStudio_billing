# frozen_string_literal: true

require_relative "../test_helper"
require "devise/test/integration_helpers"

class BillingJourneysTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  parallelize(workers: 1)

  include Devise::Test::IntegrationHelpers

  setup do
    acquire_database_lock!
    load Rails.root.join("db/seeds.rb").to_s
    @user = User.find_by!(email: "admin@admin.com")
    @workspace = Workspace.find_by!(name: "Studio Workspace")
    @workspace_root = RecordingStudio.root_recording_for(@workspace)
    @admin_root = RecordingStudio.root_recording_for(AdminRoot.find_by!(name: "Billing Administration"))
    Current.actor = nil
    RecordingStudio::RootSwitchable::Current.device_key = nil
    sign_in @user
  end

  teardown { release_database_lock! }

  test "the seeded workspace can be selected before a permitted customer billing visit" do
    select_root(@workspace_root)

    with_billing_access(true) do
      get "/billing"
    end

    assert_response :success, response.body
    assert_includes response.body, "Billing"
    assert_includes response.body, "flat-pack--sidebar-layout"
    assert_includes response.body, "flat_pack/application"
    assert_includes response.body, 'data-theme="rounded"'
    assert_includes response.body, 'data-billing-layout="recording-studio-default"'
  end

  test "customer billing routes reject an actor without billing access" do
    select_root(@workspace_root)

    with_billing_access(false) do
      get "/billing"
    end

    assert_response :not_found
  end

  test "admin operations reject an actor without Recording Studio Admin access" do
    price = RecordingStudioBilling::Price.with_current_recording.find_by!(key: "demo_monthly_plan_us_price")

    with_billing_access(false) do
      post "/billing/admin/operations/publish_price/#{price.id}"
    end

    assert_response :forbidden
  end

  test "seeded Stripe test provider fails closed before any external configuration is available" do
    provider = RecordingStudioBilling::ProviderAccount.with_current_recording.find_by!(key: "demo_stripe_test_provider")
    command = RecordingStudioBilling::FinancialCommand.find_by!(local_idempotency_key: "seed:stripe-configuration-probe")

    assert_equal "stripe", provider.adapter_key
    assert_instance_of RecordingStudioBilling::StripeAdapter, RecordingStudioBilling.provider_adapter(provider.adapter_key)
    assert_equal "failed", command.state
    assert_equal "configuration_missing", command.normalized_result.fetch("reason")
    assert_equal 1, RecordingStudioBilling::FinancialCommandAttempt.where(financial_command: command).count
  end

  test "reloading seeds keeps fake-provider fixtures and the Stripe probe idempotent" do
    load Rails.root.join("db/seeds.rb").to_s

    assert_equal 1, RecordingStudioBilling::ProviderAccount.with_current_recording.where(key: "demo_fake_provider").count
    assert_equal 1, RecordingStudioBilling::ProviderAccount.with_current_recording.where(key: "demo_stripe_test_provider").count
    assert_equal 1, RecordingStudioBilling::FinancialCommand.where(local_idempotency_key: "seed:stripe-configuration-probe").count
  end

  test "hybrid subscription changes and plan-update states are seeded through provider commands" do
    subscription = RecordingStudioBilling::Subscription.find_by!(root_recording: @workspace_root)
    modes = subscription.item_versions.order(:line_key).pluck(:mode)

    assert_includes modes, "monthly_subscription"
    assert_includes modes, "recurring_addon"
    assert_equal "scheduled", RecordingStudioBilling::SubscriptionChangeIntent.find_by!(local_idempotency_key: "seed:scheduled-change").state
    assert_equal "applied", RecordingStudioBilling::SubscriptionChangeIntent.find_by!(local_idempotency_key: "seed:applied-change").state
    assert_equal "failed", RecordingStudioBilling::SubscriptionChangeIntent.find_by!(local_idempotency_key: "seed:failed-change").state
    assert_equal "requires_review", RecordingStudioBilling::SubscriptionChangeIntent.find_by!(local_idempotency_key: "seed:uncertain-change").state
    plan_updates = RecordingStudioBilling::PlanUpdate.where(id: RecordingStudio::Recording.unscoped.where(
      root_recording: @admin_root, recordable_type: "RecordingStudioBilling::PlanUpdate"
    ).select(:recordable_id))
    plan_runs = RecordingStudioBilling::PlanUpdateRun.where(plan_update: plan_updates,
                                                            idempotency_key: %w[seed:plan-scheduled seed:plan-applied seed:plan-failed seed:plan-uncertain])
    assert_equal %w[applied failed requires_review scheduled], plan_runs.order(:state).pluck(:state)
  end

  test "invoice payment refund and adjustment are projected from completed provider commands" do
    payment = RecordingStudioBilling::Payment.find_by!(root_recording: @workspace_root)

    assert_equal "captured", payment.state
    assert_equal "captured", payment.invoice.state
    assert_equal 200, RecordingStudioBilling::Refund.find_by!(refund_intent: RecordingStudioBilling::RefundIntent.find_by!(local_idempotency_key: "seed:refund")).amount_minor
    assert_equal "credit", RecordingStudioBilling::FinancialAdjustment.find_by!(adjustment_intent: RecordingStudioBilling::AdjustmentIntent.find_by!(local_idempotency_key: "seed:adjustment")).kind
  end

  test "seeded checkout commands retain their executor-created provider references before reconciliation" do
    %w[seed:hybrid-checkout seed:active-monthly-checkout seed:usage-checkout].each do |key|
      command = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: key).financial_command
      reference = RecordingStudioBilling::ProviderReference.find_by!(financial_command: command,
                                                                      provider_adapter_key: "fake", remote_type: "operation",
                                                                      remote_id: command.provider_reference)

      assert_equal command.provider_reference, reference.remote_id
      assert_equal command.provider_account_recording_id, reference.provider_account_recording_id
    end
  end

  test "tax calculator contracts reject disabled and unsupported requests without creating projections" do
    result = RecordingStudioBilling.calculate_tax(calculator_key: "missing", tax_policy: {}, root_recording: @workspace_root,
                                                  account_recording: RecordingStudioBilling::Account.find_by!(name: "Studio Account").recording,
                                                  manifest: RecordingStudioBilling::CommercialManifest.first, transaction_type: :sale,
                                                  operation_reference: "dummy-disabled-tax", lines: [], subtotal_minor: 0,
                                                  discount_minor: 0, currency: "USD", verified_location: { country: "US" },
                                                  tax_categories: [], behavior: :exclusive, effective_at: Time.current,
                                                  idempotency_key: "dummy-disabled-tax")

    assert_equal :unsupported_tax_calculation, result.status
  end

  test "registered feature override is published through its protected reviser" do
    override = RecordingStudioBilling::FeatureOverride.with_current_recording.find_by!(key: "demo_priority_support_override")

    assert_equal true, override.value
    assert_equal "published", override.state
  end

  test "usage is recorded rated allocated closed and charged as overage" do
    event = RecordingStudioBilling::UsageEvent.find_by!(root_recording: @workspace_root, idempotency_key: "seed:usage-event")
    rated = RecordingStudioBilling::RatedUsage.find_by!(root_recording: @workspace_root)
    allocation = RecordingStudioBilling::UsageAllocation.find_by!(rated_usage: rated)
    overage = RecordingStudioBilling::OverageCalculation.find_by!(usage_allocation: allocation)

    assert_equal 6, event.quantity
    assert_equal 6, rated.quantity
    assert_equal "closed", allocation.usage_period.state
    assert_equal 6, allocation.excess_quantity
    assert_equal 30, overage.amount_minor
    overage_price = RecordingStudioBilling::OveragePrice.with_current_recording.find_by!(key: "demo_usage_api_overage")
    manifest = RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: rated.manifest_digest)

    assert_equal overage_price.recording.id, overage.overage_price_recording_id
    assert_includes manifest.canonical_data.fetch("overage_prices").map { |price| price.fetch("overage_price_recording_id") },
                    overage_price.recording.id
  end

  test "authorized invoice download streams the dummy adapter PDF privately" do
    select_root(@workspace_root)
    invoice = RecordingStudioBilling::Payment.find_by!(root_recording: @workspace_root).invoice

    with_billing_access(true) { get "/billing/invoices/#{invoice.id}/download", headers: { "ACCEPT" => "application/pdf" } }

    assert_response :success
    assert_equal "private, no-store", response.headers.fetch("Cache-Control")
    assert_equal %(attachment; filename="invoice-#{invoice.id}.pdf"), response.headers.fetch("Content-Disposition")
    assert_includes response.body, "%PDF-1.4"
  end

  private

  def select_root(root_recording)
    device_key = "billing-journey-device"
    RecordingStudio::RootSwitchable::Current.device_key = device_key
    RecordingStudio::RootSwitchable::Selection.upsert_for(
      actor: @user, device_key:, scope_key: "all_workspaces", root_recording:
    )
  end

  def with_billing_access(allowed)
    singleton_class = RecordingStudioAccessible.singleton_class
    original = singleton_class.instance_method(:authorized?)
    singleton_class.define_method(:authorized?) do |*arguments, **keywords|
      allowed.respond_to?(:call) ? allowed.call(*arguments, **keywords) : allowed
    end
    yield
  ensure
    singleton_class.define_method(:authorized?, original) if original
  end

  def acquire_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
  end

  def release_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
  end
end
