# frozen_string_literal: true

require "test_helper"

class DummyV1CatalogueTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(1_208_120_201)")
    Current.actor = nil
    load Rails.root.join("db/seeds.rb").to_s
    @workspace = Workspace.find_by!(name: "Studio Workspace")
    @admin_root = AdminRoot.find_by!(name: "Billing Administration")
    @workspace_root = RecordingStudio.root_recording_for(@workspace)
    @admin_root_recording = RecordingStudio.root_recording_for(@admin_root)
  end

  teardown do
    Current.actor = nil
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(1_208_120_201)")
  end

  test "seeds exactly one workspace admin billing account and billing admin" do
    assert_equal 1, Workspace.where(name: "Studio Workspace").count
    assert_equal 1, AdminRoot.where(name: "Billing Administration").count
    assert_equal 1, RecordingStudioBilling::Account.where(name: "Studio Account").count
    assert_equal 1, RecordingStudioBilling::BillingAdmin.where(key: "billing").count
    assert_equal "Studio Account", account_for(@workspace_root).name
    assert_equal "billing", billing_admin_for(@admin_root_recording).key
  end

  test "seeds edit access on the workspace for the dummy admin" do
    user = User.find_by!(email: "admin@admin.com")

    assert RecordingStudio.capability_enabled?(:accessible, for: Workspace)
    assert RecordingStudio.capability_enabled?(:accessible, for: AdminRoot)
    assert RecordingStudioAccessible.authorized?(actor: user, recording: @workspace_root, role: :view)
    assert RecordingStudioAccessible.authorized?(actor: user, recording: @workspace_root, role: :edit)
    assert RecordingStudioAccessible.authorized?(actor: user, recording: @admin_root_recording, role: :admin)
  end

  test "seeds the published V1 product and market price matrix" do
    products = catalogue(RecordingStudioBilling::Product)
    prices = catalogue(RecordingStudioBilling::Price)
    options = catalogue(RecordingStudioBilling::BillingOption)

    assert_equal "service", products.find_by!(key: "demo_usage_product").kind
    assert_equal "credit_pack", products.find_by!(key: "demo_credit_pack").kind
    assert_equal "credit_pack", products.find_by!(key: "demo_ai_credit_pack").kind
    assert_equal "plan", products.find_by!(key: "demo_monthly_plan").kind
    assert_equal "Pro", products.find_by!(key: "demo_monthly_plan").name
    assert_equal "Pro yearly", products.find_by!(key: "demo_annual_plan").name
    assert_equal "Free plan", products.find_by!(key: "demo_free_plan").name
    assert_equal 14, options.find_by!(key: "demo_annual_plan_option").trial_days
    assert_equal 0, options.find_by!(key: "demo_monthly_plan_option").trial_days
    assert_equal [0, 4_900, 49_000], %w[demo_free_plan demo_monthly_plan demo_annual_plan].map { |key|
      prices.find_by!(key: "#{key}_us_price").amount_minor
    }
    assert_equal 4_500, prices.find_by!(key: "demo_monthly_plan_it_price").amount_minor
    assert_equal 4_700, prices.find_by!(key: "demo_monthly_plan_de_price").amount_minor
    assert_equal "EUR", prices.find_by!(key: "demo_monthly_plan_it_price").currency_code
    assert_equal "EUR", prices.find_by!(key: "demo_monthly_plan_de_price").currency_code
    refute_equal prices.find_by!(key: "demo_annual_plan_it_price").amount_minor,
                 prices.find_by!(key: "demo_annual_plan_de_price").amount_minor
    assert_equal "allowance", catalogue(RecordingStudioBilling::Feature).find_by!(
      key: "demo_api_calls", product_recording_id: products.find_by!(key: "demo_usage_product").recording.id
    ).kind
    overage = catalogue(RecordingStudioBilling::OveragePrice).find_by!(key: "demo_usage_api_overage")
    assert_equal 50, overage.review_threshold_minor
    assert_equal 200, overage.hard_threshold_minor
    assert(prices.where(state: "published").exists?)
  end

  test "registers fake tax calculators without enabling tax" do
    policy = RecordingStudioBilling.configuration.tax_policy

    assert_includes RecordingStudioBilling.configuration.tax_calculator_registry.keys, "dummy_exclusive"
    assert_includes RecordingStudioBilling.configuration.tax_calculator_registry.keys, "dummy_inclusive"
    assert_equal false, policy.fetch(:enabled)
    assert_nil policy.fetch(:calculator_key)
  end

  test "seeds checkout presentations usage credits and a reconciliation issue" do
    hybrid = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:hybrid-checkout")
    usage = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:usage-checkout")
    credit = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:credit-pack-checkout")
    free = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:checkout-no-charge")

    assert_equal "embedded", hybrid.items.first.presentation
    assert_equal "no_charge", free.items.first.presentation
    assert_equal "completed", free.state
    assert_equal "redirect", RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:checkout-redirect").items.first.presentation
    assert_equal "payment_link", RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:checkout-payment-link").items.first.presentation
    assert_equal "invoice", RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:checkout-invoice").items.first.presentation
    invoice = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:checkout-invoice")
    assert_equal "awaiting_confirmation", invoice.state
    italy = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:checkout-italy")
    germany = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "seed:checkout-germany")
    assert_equal 4_500, italy.items.first.commercial_manifest.dig("canonical_data", "price", "amount_minor")
    assert_equal 4_700, germany.items.first.commercial_manifest.dig("canonical_data", "price", "amount_minor")
    assert_equal "EUR", italy.items.first.currency_code
    assert_equal "EUR", germany.items.first.currency_code
    refute_equal italy.items.first.price_recording_id, germany.items.first.price_recording_id
    assert_equal "monthly_subscription", usage_item_mode(usage)
    assert_equal "one_off_credit_pack", credit.items.first.then { |item|
      RecordingStudioBilling::Purchase.with_current_recording.find_by!(checkout_intent_item_id: item.id).mode
    }
    credit_purchase = credit.items.first.then { |item|
      RecordingStudioBilling::Purchase.with_current_recording.find_by!(checkout_intent_item_id: item.id)
    }
    assert_equal "RecordingStudioBilling::Account", credit_purchase.recording.parent_recording.recordable_type
    assert_equal account_for(@workspace_root).recording.id, credit_purchase.recording.parent_recording_id
    assert RecordingStudioBilling::UsageCreditGrant.exists?(root_recording: @workspace_root, source_key: "seed:usage-allowance", grant_kind: "allowance", quantity: 5)
    assert RecordingStudioBilling::UsageCreditGrant.exists?(root_recording: @workspace_root, source_key: "seed:credit-pack-grant", grant_kind: "credit", quantity: 1_000)
    api = RecordingStudioBilling.meter_credits(root_recording: @workspace_root, meter_key: "demo_api_calls")
    assert_equal 1_000, api.purchased
    assert_equal 11, api.used
    assert_equal 989, api.remaining
    assert_equal 989, RecordingStudioBilling.remaining_credits(root_recording: @workspace_root, meter_key: "demo_api_calls")
    assert_equal 0, RecordingStudioBilling.remaining_credits(root_recording: @workspace_root, meter_key: "demo_ai_credits")
    assert RecordingStudioBilling::ReconciliationIssue.exists?(kind: "provider_result_mismatch")
    assert RecordingStudioBilling::RefundIntent.exists?(local_idempotency_key: "seed:uncertain-refund")
  end

  private

  def catalogue(model)
    model.where(id: RecordingStudio::Recording.where(root_recording: @admin_root_recording,
                                                     recordable_type: model.name).select(:recordable_id))
  end

  def account_for(root)
    RecordingStudio::Recording.unscoped.find_by!(
      root_recording: root, parent_recording: root, recordable_type: "RecordingStudioBilling::Account"
    ).recordable
  end

  def billing_admin_for(root)
    RecordingStudio::Recording.unscoped.find_by!(
      root_recording: root, parent_recording: root, recordable_type: "RecordingStudioBilling::BillingAdmin"
    ).recordable
  end

  def usage_item_mode(intent)
    RecordingStudioBilling::SubscriptionLine.find_by!(checkout_intent_item_id: intent.items.first.id).mode
  end
end
