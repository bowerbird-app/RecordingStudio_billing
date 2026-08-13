# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require "rails/test_help"
require "devise/test/integration_helpers"

class BillingUiCheckoutIntegrationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    BillingTestDatabaseCleanup.clear!
    RecordingStudioBilling.configuration.reset_registries!
    @billing_location_context_resolver = RecordingStudioBilling.configuration.billing_location_context_resolver
    RecordingStudioBilling.configuration.billing_location_context_resolver = lambda do |**|
      { host_country: RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("IT", :host) }
    end
    @access_management_authorizer = RecordingStudioAccessible.configuration.access_management_authorizer
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }
    @authorized = RecordingStudioAccessible.method(:authorized?)
    RecordingStudioAccessible.define_singleton_method(:authorized?) { |**| true }
    @user = User.create!(email: "billing-ui-#{SecureRandom.hex(4)}@example.com", password: "Password1!",
                         password_confirmation: "Password1!")
    @root, @option = published_checkout_option
    Current.actor = @user
    sign_in @user
    switch_root(@root)
  end

  teardown do
    Current.actor = nil
    RecordingStudioAccessible.define_singleton_method(:authorized?, @authorized)
    RecordingStudioAccessible.configuration.access_management_authorizer = @access_management_authorizer
    RecordingStudioBilling.configuration.billing_location_context_resolver = @billing_location_context_resolver
    BillingTestDatabaseCleanup.clear!
  end

  test "same rendered checkout form creates one intent command and attempt" do
    parameters = selection_params

    post "/billing/billing/checkout", params: parameters
    assert_redirected_to %r{/billing/checkout/}
    first_intent = RecordingStudioBilling::CheckoutIntent.for_root(@root).sole
    assert_redirected_to "/billing/checkout/#{first_intent.id}?root_recording_id=#{@root.id}"

    post "/billing/billing/checkout", params: parameters

    assert_redirected_to "/billing/checkout/#{first_intent.id}?root_recording_id=#{@root.id}"
    assert_equal 1, RecordingStudioBilling::CheckoutIntent.for_root(@root).count
    assert_equal 1, RecordingStudioBilling::FinancialCommand.where(root_recording: @root).count
    assert_equal 1, first_intent.reload.attempts.count
  end

  test "same checkout request key with changed selection redirects safely without a second command" do
    post "/billing/billing/checkout", params: selection_params

    post "/billing/billing/checkout", params: selection_params(quantity: 2)

    assert_redirected_to %r{/billing/billing/plan\?root_recording_id=}
    assert_equal 1, RecordingStudioBilling::CheckoutIntent.for_root(@root).count
    assert_equal 1, RecordingStudioBilling::FinancialCommand.where(root_recording: @root).count
  end

  test "missing malformed and client-authoritative selection input redirects safely" do
    [
      {},
      { checkout_request_key: SecureRandom.hex(16) },
      { checkout_request_key: SecureRandom.hex(16), items: "invalid" },
      selection_params(items: { "0" => { billing_option_recording_id: @option.recording.id, amount_minor: 1,
                                         provider: "forged", tax: "forged", url: "https://evil.example", market: "forged", total: 1 } })
    ].each do |parameters|
      post "/billing/billing/checkout", params: parameters

      assert_redirected_to %r{/billing/billing/plan\?root_recording_id=}
    end

    assert_equal 0, RecordingStudioBilling::CheckoutIntent.for_root(@root).count
  end

  test "subscription confirmation GETs are read-only, POST creates one durable intent, and cross-root routes are hidden" do
    root, option = published_checkout_option(recurrence: "recurring", interval: "month")
    subscription = project_recurring_subscription(root, option)
    use_subscription_change_adapter!
    switch_root(root)
    item = subscription.items.sole
    version_count = item.versions.count

    get "/billing/subscriptions/#{subscription.id}/cancel_confirmation", params: { root_recording_id: root.id }
    assert_response :success
    get "/billing/subscriptions/#{subscription.id}/resume_confirmation", params: { root_recording_id: root.id }
    assert_response :success
    assert_equal 0, RecordingStudioBilling::SubscriptionChangeIntent.where(subscription:).count
    assert_equal "active", subscription.reload.state
    assert_equal version_count, item.reload.versions.count

    post "/billing/subscriptions/#{subscription.id}/cancel", params: { root_recording_id: root.id }
    assert_redirected_to %r{/billing/subscription_changes/}
    post "/billing/subscriptions/#{subscription.id}/cancel", params: { root_recording_id: root.id }
    assert_equal 1, RecordingStudioBilling::SubscriptionChangeIntent.where(subscription:).count
    assert_equal "active", subscription.reload.state
    assert_equal version_count, item.reload.versions.count
    cancellation = RecordingStudioBilling::SubscriptionChangeIntent.where(subscription:).sole
    cancellation.financial_command.update!(state: "failed", normalized_result: { "reason" => "provider_rejected" })
    assert_raises(ArgumentError) do
      RecordingStudioBilling::ApplySubscriptionChangeIntent.call(subscription_change_intent: cancellation,
                                                                 root_recording: root)
    end
    get "/billing/subscription_changes/#{cancellation.id}", params: { root_recording_id: root.id }
    assert_response :success
    assert_match(/Failed/, response.body)
    assert_equal "active", subscription.reload.state
    assert_equal version_count, item.reload.versions.count

    post "/billing/subscriptions/#{subscription.id}/resume", params: { root_recording_id: root.id }
    review = RecordingStudioBilling::SubscriptionChangeIntent.where(subscription:).order(:created_at).last
    review.financial_command.update!(state: "requires_reconciliation",
                                     normalized_result: { "reason" => "provider_unknown" })
    assert_raises(ArgumentError) do
      RecordingStudioBilling::ApplySubscriptionChangeIntent.call(subscription_change_intent: review,
                                                                 root_recording: root)
    end
    get "/billing/subscription_changes/#{review.id}", params: { root_recording_id: root.id }
    assert_response :success
    assert_match(/Requires review/, response.body)
    assert_equal "active", subscription.reload.state
    assert_equal version_count, item.reload.versions.count

    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: other_root, name: "Other")
    switch_root(other_root)
    get "/billing/subscriptions/#{subscription.id}/cancel_confirmation", params: { root_recording_id: other_root.id }
    assert_response :not_found
    post "/billing/subscriptions/#{subscription.id}/cancel", params: { root_recording_id: other_root.id }
    assert_response :not_found
  end

  private

  def selection_params(quantity: 1, items: nil)
    {
      scope: "all_workspaces",
      checkout_request_key: "a" * 32,
      country_code: "IT",
      items: items || { "0" => { billing_option_recording_id: @option.recording.id, quantity: quantity } }
    }
  end

  def switch_root(root)
    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces", root_switch: { root_recording_id: root.id, return_to: "/" }
    }
    assert_response :redirect
  end

  def published_checkout_option(recurrence: "one_time", interval: nil)
    provider_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: provider_root,
                                                        key: "billing_#{SecureRandom.hex(4)}")
    provider = record_child(
      RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: admin.recording,
                                                  key: "provider_#{SecureRandom.hex(4)}", adapter_key: "fake", name: "Fake", environment: "test", configuration: {}, capabilities: [], supported_markets: ["IT"], supported_currencies: ["EUR"]), provider_root, admin.recording
    )
    market = record_child(
      RecordingStudioBilling::Market.new(provider_account_recording: provider, key: "market_#{SecureRandom.hex(4)}",
                                         country_codes: ["IT"], country_groups: {}, regional_country_codes: [], global_fallback: false, allowed_currency_codes: ["EUR"], default_currency_code: "EUR", priority: 1, specificity: 1, ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive", verification_policy: "requote"), provider_root, admin.recording
    )
    product = record_child(
      RecordingStudioBilling::Product.new(provider_account_recording: provider, key: "product_#{SecureRandom.hex(4)}",
                                          kind: "service", feature_values: {}), provider_root, admin.recording
    )
    option_recording = record_child(
      RecordingStudioBilling::BillingOption.new(product_recording: product, key: "option_#{SecureRandom.hex(4)}",
                                                recurrence:, interval:, interval_count: interval && 1, quantity_mode: "adjustable", minimum_quantity: 1, maximum_quantity: 3, default_quantity: 1, pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0, trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive", feature_values: {}), provider_root, product
    )
    price = record_child(
      RecordingStudioBilling::Price.new(billing_option_recording: option_recording, market_recording: market,
                                        key: "price_#{SecureRandom.hex(4)}", amount_minor: 1_000, currency_code: "EUR", currency_exponent: 2, pricing_model: "flat", version: 1, scope: "default", feature_values: {}), provider_root, option_recording
    )
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: provider_root,
                                                         price_recording_ids: [price.id], actor: @user)
    register_fake_checkout_adapter!
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Customer #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: root, name: "Customer #{SecureRandom.hex(4)}")
    [root,
      RecordingStudioBilling::BillingOption.joins(:recording).find_by!(recording_studio_recordings: { id: option_recording.id })]
  end

  def record_child(recordable, root, parent)
    RecordingStudio::Recording.unscoped.find(RecordingStudio.record!(action: "created", recordable: recordable,
                                                                     root_recording: root, parent_recording: parent).recording.id)
  end

  def register_fake_checkout_adapter!
    return if RecordingStudioBilling.configuration.provider_registry.registered?("fake")

    RecordingStudioBilling.register_provider(
      "fake",
      RecordingStudioBilling::FakeFinancialAdapter.new(
        outcome: :success,
        capabilities: RecordingStudioBilling::ProviderCapabilities.new(
          operations: ["checkout"], currencies: ["EUR"], markets: ["IT"], collection_methods: ["automatic"],
          checkout_modes: ["redirect"], quantities: ["adjustable"], composition: ["single"]
        )
      )
    )
  end

  def project_recurring_subscription(root, option)
    intent = RecordingStudioBilling.create_checkout_intent(
      root_recording: root, local_idempotency_key: "recurring-#{SecureRandom.uuid}", country_code: "IT",
      items: [{ billing_option_recording_id: option.recording.id, quantity: 1 }]
    ).intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: root)
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: root).subscription
  end

  def use_subscription_change_adapter!
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider("fake",
                                             RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success))
  end
end
