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

    get "/billing"

    assert_response :success, response.body
    assert_includes response.body, "Billing"
    assert_includes response.body, "Pro"
    assert_includes response.body, "$49"
    assert_includes response.body, "Change plan"
    assert_includes response.body, "Cancel plan"
    refute_includes response.body, "View plans"
    refute_includes response.body, "Active"
    assert_operator response.body.index("Change plan"), :<, response.body.index("Cancel plan")
    refute_includes response.body[response.body.index("Change plan")..response.body.index("Cancel plan")], "border-t"
    assert_includes response.body, 'data-recording-studio-default-layout="true"'
    assert_select "html[data-theme=rounded]"
    assert_includes response.body, "flat-pack-page-nav"
    refute_includes response.body, "flat-pack--sidebar-layout"
    refute_includes response.body, "data-billing-layout"
    refute_includes response.body, "Current versions"
    refute_includes response.body, "Market:"
    refute_includes response.body, "Sign out"
    refute_includes response.body, "Sign in"
    refute_includes response.body, "recording_studio_root_switch_dropdown"
  end

  test "customer billing routes reject an actor without billing access" do
    outsider = User.create!(
      email: "no-billing-#{SecureRandom.hex(4)}@example.test",
      password: "Password",
      password_confirmation: "Password"
    )
    sign_in outsider
    select_root(@workspace_root, actor: outsider)

    get "/billing"

    assert_response :not_found
  end

  test "admin operations reject an actor without Recording Studio Admin access" do
    outsider = User.create!(
      email: "no-admin-#{SecureRandom.hex(4)}@example.test",
      password: "Password",
      password_confirmation: "Password"
    )
    sign_in outsider
    price = RecordingStudioBilling::Price.with_current_recording.find_by!(key: "demo_monthly_plan_us_price")

    post "/billing/admin/operations/publish_price/#{price.id}"

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
    hybrid = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:hybrid-checkout")
    subscription = RecordingStudioBilling::SubscriptionLine.find_by!(
      checkout_intent_item_id: hybrid.items.first.id
    ).subscription
    modes = subscription.lines.order(:line_key).pluck(:mode)

    assert_includes modes, "monthly_subscription"
    assert_includes modes, "recurring_addon"
    assert_equal "scheduled", RecordingStudioBilling::SubscriptionChangeIntent.find_by!(local_idempotency_key: "seed:scheduled-change").state
    assert_equal "applied", RecordingStudioBilling::SubscriptionChangeIntent.find_by!(local_idempotency_key: "seed:applied-change").state
    assert_equal "failed", RecordingStudioBilling::SubscriptionChangeIntent.find_by!(local_idempotency_key: "seed:failed-change").state
    assert_equal "requires_review", RecordingStudioBilling::SubscriptionChangeIntent.find_by!(local_idempotency_key: "seed:uncertain-change").state
    assert_equal "active", subscription.current.state
    assert subscription.active_lines.where(mode: "monthly_subscription").exists?
    plan_updates = RecordingStudioBilling::PlanUpdate.where(id: RecordingStudio::Recording.unscoped.where(
      root_recording: @admin_root, recordable_type: "RecordingStudioBilling::PlanUpdate"
    ).select(:recordable_id))
    plan_runs = RecordingStudioBilling::PlanUpdateRun.where(plan_update: plan_updates,
                                                            idempotency_key: %w[seed:plan-scheduled seed:plan-applied seed:plan-failed seed:plan-uncertain])
    assert_equal %w[applied failed requires_review scheduled], plan_runs.order(:state).pluck(:state)
  end

  test "invoice payment refund and adjustment are projected from completed provider commands" do
    command = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:hybrid-checkout").financial_command
    payment = RecordingStudioBilling::Payment.find_by!(financial_command: command)

    assert_equal "paid", payment.state
    assert_equal "paid", payment.invoice.state
    assert_equal "paid", command.normalized_result["payment_state"]
    assert_equal 200, RecordingStudioBilling::Refund.find_by!(refund_intent: RecordingStudioBilling::RefundIntent.find_by!(local_idempotency_key: "seed:refund")).amount_minor
    assert_equal "credit", RecordingStudioBilling::FinancialAdjustment.find_by!(adjustment_intent: RecordingStudioBilling::AdjustmentIntent.find_by!(local_idempotency_key: "seed:adjustment")).kind
    assert_equal "requires_reconciliation", RecordingStudioBilling::RefundIntent.find_by!(local_idempotency_key: "seed:uncertain-refund").financial_command.state
  end

  test "seeded checkout commands retain their executor-created provider references before reconciliation" do
    %w[seed:hybrid-checkout seed:active-monthly-checkout seed:usage-checkout seed:credit-pack-checkout].each do |key|
      command = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: key).financial_command
      reference = RecordingStudioBilling::ProviderReference.find_by!(financial_command: command,
                                                                      provider_adapter_key: "fake", remote_type: "operation",
                                                                      remote_id: command.provider_reference)

      assert_equal command.provider_reference, reference.remote_id
      assert_equal command.provider_account_recording_id, reference.provider_account_recording_id
    end
  end

  test "seeded checkout presentations and Italy vs Germany euro prices render through checkout" do
    select_root(@workspace_root)
    expected = {
      "seed:checkout-redirect" => "Continue to secure checkout",
      "seed:checkout-payment-link" => "Open payment link",
      "seed:checkout-invoice" => "Continue to invoice",
      "seed:checkout-no-charge" => "No payment is due for this plan."
    }

    expected.each do |key, copy|
      intent = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: key)
      get "/billing/checkout/#{intent.id}", params: { root_recording_id: @workspace_root.id }

      assert_response :success, "#{key}: #{response.body}"
      assert_includes response.body, copy
      refute_includes response.body, "Market:"
      refute_includes response.body, "Overage policy"
      assert_includes response.body, "Tax is calculated at checkout"

      get "/billing/checkout/#{intent.id}/return", params: { root_recording_id: @workspace_root.id }

      assert_response :success
      assert_equal intent.reload.state, RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: key).state
    end

    italy = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:checkout-italy")
    germany = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:checkout-germany")
    get "/billing/checkout/#{italy.id}", params: { root_recording_id: @workspace_root.id }
    assert_response :success
    assert_includes response.body, "4500 EUR"
    refute_includes response.body, "4700 EUR"

    get "/billing/checkout/#{germany.id}", params: { root_recording_id: @workspace_root.id }
    assert_response :success
    assert_includes response.body, "4700 EUR"
    refute_includes response.body, "4500 EUR"
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

    assert_equal 11, event.quantity
    assert_equal 11, rated.quantity
    assert_equal "closed", allocation.usage_period.state
    assert_equal 5, allocation.credited_quantity
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
    invoice = RecordingStudioBilling::Payment.find_by!(
      financial_command: RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:hybrid-checkout").financial_command
    ).invoice

    get "/billing/invoices/#{invoice.id}/download", headers: { "ACCEPT" => "application/pdf" }

    assert_response :success
    assert_equal "private, no-store", response.headers.fetch("Cache-Control")
    assert_equal %(attachment; filename="invoice-#{invoice.id}.pdf"), response.headers.fetch("Content-Disposition")
    assert_includes response.body, "%PDF-1.4"
  end

  test "plan invoices payments and portal show hybrid money changes and restricted payment details" do
    select_root(@workspace_root)

    get "/billing/plan", params: { root_recording_id: @workspace_root.id }
    assert_response :redirect
    assert_includes response.redirect_url, "/plans"
    assert_includes response.redirect_url, @workspace_root.id.to_s

    get "/plans", params: { root_recording_id: @workspace_root.id }
    assert_response :success, response.body
    assert_includes response.body, "Pro"
    assert_includes response.body, "Current"
    assert_includes response.body, "disabled"
    refute_includes response.body, "data-flat-pack-plan-picker=\"cta-spacer\""
    refute_includes response.body, "Current plan"
    assert_includes response.body, "$0"
    assert_includes response.body, "$49"
    assert_includes response.body, "$490"
    assert_includes response.body, "Free plan"
    assert_includes response.body, "Pro yearly"
    refute_includes response.body, "Annual plan"
    assert_includes response.body, "Choose a plan"
    assert_includes response.body, "Pick the plan that fits this workspace"
    assert_includes response.body, "Choose plan"
    refute_includes response.body, "Choose this plan"
    assert_includes response.body, 'data-recording-studio-default-layout="true"'
    assert_includes response.body, "flat-pack-page-nav"
    refute_includes response.body, "$51"
    refute_includes response.body, "Usage ·"
    refute_includes response.body, "Cancel plan"
    refute_includes response.body, "Scheduled"

    get "/billing/plan_requests", params: { root_recording_id: @workspace_root.id }
    assert_response :success, response.body
    assert_includes response.body, "Plan requests"
    assert_includes response.body, "Scheduled"
    assert_includes response.body, "Applied"
    assert_includes response.body, "Failed"
    assert_includes response.body, "Waiting for confirmation"

    subscription = RecordingStudioBilling::SubscriptionLine.find_by!(
      checkout_intent_item_id: RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:active-monthly-checkout").items.first.id
    ).subscription
    change_count = RecordingStudioBilling::SubscriptionChangeIntent.count
    get "/billing/subscriptions/#{subscription.id}/cancel_confirmation", params: { root_recording_id: @workspace_root.id }
    assert_response :success
    assert_includes response.body, "Past charges stay on your invoices"
    assert_includes response.body, "Effective"
    assert_equal change_count, RecordingStudioBilling::SubscriptionChangeIntent.count

    get "/billing/subscriptions/#{subscription.id}/cancel", params: { root_recording_id: @workspace_root.id }
    assert_response :not_found
    assert_equal change_count, RecordingStudioBilling::SubscriptionChangeIntent.count

    get "/billing/invoices", params: { root_recording_id: @workspace_root.id }
    assert_response :success
    assert_includes response.body, "Waiting for confirmation"

    get "/billing/payments", params: { root_recording_id: @workspace_root.id }
    assert_response :success
    assert_includes response.body, "Refund"
    assert_includes response.body, "Waiting for confirmation"

    get "/billing/settings", params: { root_recording_id: @workspace_root.id }
    assert_response :success
    assert_includes response.body, "Manage payment details"
    assert_includes response.body, "payment portal"

    post "/billing/portal", params: { root_recording_id: @workspace_root.id }
    assert_redirected_to "http://www.example.com/dummy_portal"
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Payment methods"
    assert_includes response.body, "Tax IDs"
    assert_includes response.body, "Invoice history"
    refute_includes response.body, "Cancel plan"
    refute_includes response.body, "Change plan"
    refute_includes response.body, "Confirm cancellation"
  end

  private

  def select_root(root_recording, actor: @user)
    get "/"
    assert_response :success
    device_key = cookies[RecordingStudioRootSwitchable.configuration.device_key_cookie_name]
    RecordingStudio::RootSwitchable::Selection.upsert_for(
      actor:, device_key:, scope_key: "all_workspaces", root_recording:
    )
  end

  def acquire_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
  end

  def release_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
  end
end
