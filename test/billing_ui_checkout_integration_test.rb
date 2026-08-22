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
    acquire_database_lock!
    BillingTestDatabaseCleanup.clear!
    RecordingStudioBilling.configuration.reset_registries!
    @billing_location_context_resolver = RecordingStudioBilling.configuration.billing_location_context_resolver
    RecordingStudioBilling.configuration.billing_location_context_resolver = lambda do |**|
      { host_country: RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("IT", :host) }
    end
    @user = User.create!(email: "billing-ui-#{SecureRandom.hex(4)}@example.com", password: "Password1!",
                         password_confirmation: "Password1!")
    @root, @option = published_checkout_option(adapter_key: stripe_embedded_checkout_test? ? "stripe" : "fake")
    bootstrap = RecordingStudioAccessible.bootstrap_owner_access!(recording: @root, actor: @user)
    raise bootstrap.error unless bootstrap.success?
    Current.actor = @user
    sign_in @user
    switch_root(@root)
  rescue StandardError
    BillingTestDatabaseCleanup.clear! if @database_lock_held
    release_database_lock!
    raise
  end

  teardown do
    Current.actor = nil
    RecordingStudioBilling.configuration.billing_location_context_resolver = @billing_location_context_resolver
    BillingTestDatabaseCleanup.clear! if @database_lock_held
  ensure
    release_database_lock!
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

  test "plans-style checkout without country_code uses trusted host market context" do
    post "/billing/billing/checkout", params: {
      checkout_request_key: SecureRandom.hex(16),
      items: { "0" => { billing_option_recording_id: @option.recording.id } }
    }

    assert_redirected_to %r{/billing/checkout/}
    intent = RecordingStudioBilling::CheckoutIntent.for_root(@root).sole
    assert_equal "pending_provider", intent.state
    assert_equal ["IT"], intent.items.first.market_recording.recordable.country_codes
  end

  test "plans-style checkout without country or host evidence fails closed" do
    RecordingStudioBilling.configuration.billing_location_context_resolver = nil

    post "/billing/billing/checkout", params: {
      checkout_request_key: SecureRandom.hex(16),
      items: { "0" => { billing_option_recording_id: @option.recording.id } }
    }

    assert_redirected_to %r{/plans\?root_recording_id=}
    assert_equal 0, RecordingStudioBilling::CheckoutIntent.for_root(@root).count
  end

  test "same checkout request key with changed selection redirects safely without a second command" do
    post "/billing/billing/checkout", params: selection_params

    post "/billing/billing/checkout", params: selection_params(quantity: 2)

    assert_redirected_to %r{/plans\?root_recording_id=}
    assert_equal 1, RecordingStudioBilling::CheckoutIntent.for_root(@root).count
    assert_equal 1, RecordingStudioBilling::FinancialCommand.where(root_recording: @root).count
  end

  test "Stripe embedded checkout mounts transient data and browser return cannot fulfil the intent" do
    use_stripe_embedded_checkout_adapter!
    sign_in @user
    switch_root(@root)

    intent = create_embedded_checkout_intent(quantity: 2)
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: @root)
    command = intent.reload.financial_command

    get "/billing/checkout/#{intent.id}", params: { root_recording_id: @root.id }

    assert_response :success
    assert_select "[data-stripe-checkout-client-secret='cs_test_embedded_secret']"
    assert_select "[data-stripe-publishable-key='pk_test_embedded']"
    assert_includes response.body, "https://js.stripe.com/v3/"
    assert_select "script[type='module'][src*='recording_studio_billing/stripe_checkout']"
    assert_includes response.body, "2 x 1000 EUR"
    refute_includes response.body, 'import "recording_studio_billing/stripe_checkout"'
    refute_includes response.body, "import 'recording_studio_billing/stripe_checkout'"
    persisted = [intent.attributes, command.attributes, intent.attempts.map(&:attributes)].inspect
    refute_includes persisted, "cs_test_embedded_secret"
    refute_includes persisted, "pk_test_embedded"

    get "/billing/checkout/#{intent.id}/return", params: { root_recording_id: @root.id }

    assert_response :success
    assert_equal "awaiting_confirmation", intent.reload.state
    assert_equal "succeeded", command.reload.state
  end

  test "pending Stripe checkout session presents while provider confirmation remains open" do
    use_pending_stripe_session_checkout_adapter!
    sign_in @user
    switch_root(@root)

    intent = create_embedded_checkout_intent(quantity: 1)
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: @root)
    command = intent.reload.financial_command

    assert_equal "pending_provider", intent.state
    assert_equal "requires_reconciliation", command.state
    assert_equal true, command.normalized_result["checkout_session_created"]
    assert command.provider_reference?

    get "/billing/checkout/#{intent.id}", params: { root_recording_id: @root.id }

    assert_response :success
    assert_select "[data-checkout-intent-state=pending_provider]"
    assert_select "[data-stripe-checkout-client-secret='cs_test_pending_secret']"
    assert_select "[data-stripe-publishable-key='pk_test_pending']"
    assert_includes response.body, "https://js.stripe.com/v3/"
    persisted = [intent.attributes, command.attributes, intent.attempts.map(&:attributes)].inspect
    refute_includes persisted, "cs_test_pending_secret"
    refute_includes persisted, "pk_test_pending"

    get "/billing/checkout/#{intent.id}/return", params: { root_recording_id: @root.id }

    assert_response :success
    assert_equal "pending_provider", intent.reload.state
    assert_equal "requires_reconciliation", command.reload.state
  end

  test "pending provider checkout without a created session does not mount presentation" do
    use_pending_timeout_checkout_adapter!
    sign_in @user
    switch_root(@root)

    intent = create_embedded_checkout_intent(quantity: 1)
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: @root)
    command = intent.reload.financial_command

    assert_equal "pending_provider", intent.state
    assert_equal "requires_reconciliation", command.state
    refute command.provider_reference?
    refute_equal true, command.normalized_result["checkout_session_created"]

    get "/billing/checkout/#{intent.id}", params: { root_recording_id: @root.id }

    assert_response :success
    assert_select "[data-checkout-intent-state=pending_provider]"
    refute_includes response.body, "data-stripe-checkout-client-secret"
    refute_includes response.body, "data-stripe-publishable-key"
    refute_includes response.body, "https://js.stripe.com/v3/"
  end

  test "checkout pages render redirect payment link invoice and no-charge without fulfilling on return" do
    use_presentation_checkout_adapter!
    root, option = published_checkout_option(adapter_key: "fake")
    switch_root(root)
    expected = {
      "redirect" => "Continue to secure checkout",
      "payment_link" => "Open payment link",
      "invoice" => "Continue to invoice"
    }

    expected.each do |presentation, copy|
      intent = create_presented_checkout_intent(root, option, presentation:)
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: root)

      get "/billing/checkout/#{intent.id}", params: { root_recording_id: root.id }

      assert_response :success
      assert_select "[data-checkout-intent-state=awaiting_confirmation]"
      assert_includes response.body, copy
      assert_includes response.body, "https://checkout.example.test/#{presentation}"
      assert_includes response.body, "Tax is calculated at checkout"
      refute_includes response.body, "Market:"
      refute_includes response.body, "Overage policy"

      get "/billing/checkout/#{intent.id}/return", params: { root_recording_id: root.id }

      assert_response :success
      assert_equal "awaiting_confirmation", intent.reload.state
    end

    free_root, free_option = published_checkout_option(adapter_key: "fake", amount_minor: 0)
    switch_root(free_root)
    free = create_presented_checkout_intent(free_root, free_option, presentation: "no_charge")
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: free, root_recording: free_root)

    get "/billing/checkout/#{free.id}", params: { root_recording_id: free_root.id }

    assert_response :success
    assert_includes response.body, "No payment is due for this plan."
    refute_includes response.body, "Continue to secure checkout"
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

      assert_redirected_to %r{/plans\?root_recording_id=}
    end

    assert_equal 0, RecordingStudioBilling::CheckoutIntent.for_root(@root).count
  end

  test "direct requests for disabled or duplicate checkout options redirect without persistence" do
    disabled_root, disabled_option = published_checkout_option(checkout_policy: "disabled")
    switch_root(disabled_root)
    post "/billing/billing/checkout", params: selection_params(items: {
                                                                 "0" => { billing_option_recording_id: disabled_option.recording.id, quantity: 1 }
                                                               })

    assert_redirected_to %r{/plans\?root_recording_id=}
    assert_equal 0, RecordingStudioBilling::CheckoutIntent.for_root(disabled_root).count

    switch_root(@root)
    post "/billing/billing/checkout", params: selection_params(items: {
                                                                 "0" => { billing_option_recording_id: @option.recording.id, quantity: 1 },
                                                                 "1" => { billing_option_recording_id: @option.recording.id, quantity: 1 }
                                                               })

    assert_redirected_to %r{/plans\?root_recording_id=}
    assert_equal 0, RecordingStudioBilling::CheckoutIntent.for_root(@root).count
  end

  test "subscription confirmation GETs are read-only, POST creates one durable intent, and cross-root routes are hidden" do
    root, option = published_checkout_option(recurrence: "recurring", interval: "month", product_kind: "plan")
    subscription = project_recurring_subscription(root, option)
    use_subscription_change_adapter!
    switch_root(root)
    subscription_recording = subscription.recording
    line_key = subscription.lines.sole.line_key
    line_snapshots = RecordingStudioBilling::SubscriptionLine.where(subscription_recording_id: subscription_recording.id,
                                                                    line_key:)
    snapshot_count = line_snapshots.count

    get "/billing", params: { root_recording_id: root.id }
    assert_response :success
    assert_includes response.body, "Monthly plan"
    assert_includes response.body, "View plans"
    assert_includes response.body, "Cancel plan"
    refute_includes response.body, "Current versions"
    refute_includes response.body, "Market:"

    get "/billing/subscriptions/#{subscription.id}/cancel_confirmation", params: { root_recording_id: root.id }
    assert_response :success
    get "/billing/subscriptions/#{subscription.id}/resume_confirmation", params: { root_recording_id: root.id }
    assert_response :success
    assert_equal 0, RecordingStudioBilling::SubscriptionChangeIntent.where(subscription_recording:).count
    assert_equal "active", subscription.current.state
    assert_equal snapshot_count, line_snapshots.count

    post "/billing/subscriptions/#{subscription.id}/cancel", params: { root_recording_id: root.id }
    assert_redirected_to %r{/billing/subscription_changes/}
    post "/billing/subscriptions/#{subscription.id}/cancel", params: { root_recording_id: root.id }
    assert_equal 1, RecordingStudioBilling::SubscriptionChangeIntent.where(subscription_recording:).count
    assert_equal "active", subscription.current.state
    assert_equal snapshot_count, line_snapshots.count
    cancellation = RecordingStudioBilling::SubscriptionChangeIntent.where(subscription_recording:).sole
    cancellation.financial_command.update!(state: "failed", normalized_result: { "reason" => "provider_rejected" })
    assert_raises(ArgumentError) do
      RecordingStudioBilling::ApplySubscriptionChangeIntent.call(subscription_change_intent: cancellation,
                                                                 root_recording: root)
    end
    get "/billing/subscription_changes/#{cancellation.id}", params: { root_recording_id: root.id }
    assert_response :success
    assert_match(/Failed/, response.body)
    assert_equal "active", subscription.current.state
    assert_equal snapshot_count, line_snapshots.count

    post "/billing/subscriptions/#{subscription.id}/resume", params: { root_recording_id: root.id }
    review = RecordingStudioBilling::SubscriptionChangeIntent.where(subscription_recording:).order(:created_at).last
    review.financial_command.update!(state: "requires_reconciliation",
                                     normalized_result: { "reason" => "provider_unknown" })
    assert_raises(ArgumentError) do
      RecordingStudioBilling::ApplySubscriptionChangeIntent.call(subscription_change_intent: review,
                                                                 root_recording: root)
    end
    get "/billing/subscription_changes/#{review.id}", params: { root_recording_id: root.id }
    assert_response :success
    assert_match(/Waiting for confirmation/, response.body)
    assert_equal "active", subscription.current.state
    assert_equal snapshot_count, line_snapshots.count

    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: other_root, name: "Other")
    switch_root(other_root)
    get "/billing/subscriptions/#{subscription.id}/cancel_confirmation", params: { root_recording_id: other_root.id }
    assert_response :not_found
    post "/billing/subscriptions/#{subscription.id}/cancel", params: { root_recording_id: other_root.id }
    assert_response :not_found
  end

  test "addons route renders a projected credit pack effect from the selected root only" do
    root, option = published_checkout_option(product_kind: "credit_pack")
    intent = RecordingStudioBilling.create_checkout_intent(
      root_recording: root, local_idempotency_key: "credit-pack-#{SecureRandom.uuid}", country_code: "IT",
      items: [{ billing_option_recording_id: option.recording.id, quantity: 2 }]
    ).intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: root)
    purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: root).purchase
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: other_root, name: "Other")
    switch_root(root)

    get "/billing/billing/addons", params: { root_recording_id: root.id }

    assert_response :success
    assert_includes response.body, "Credit pack"
    assert_includes response.body, "2 x 1000 EUR"
    assert_includes response.body, "one-time"
    refute_includes response.body, "One off credit pack"
    main = response.body[%r{<main class="[^"]*p-6[^"]*">.*?</main>}m]
    assert main.present?, response.body
    refute_includes main, other_root.id
    assert_equal "one_off_credit_pack", purchase.mode
  end

  private

  def acquire_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
    @database_lock_held = true
  end

  def release_database_lock!
    return unless @database_lock_held

    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{BillingTestDatabaseCleanup::LOCK_NAMESPACE})")
    @database_lock_held = false
  end

  def selection_params(quantity: 1, items: nil)
    {
      scope: "all_workspaces",
      checkout_request_key: "a" * 32,
      country_code: "IT",
      items: items || { "0" => { billing_option_recording_id: @option.recording.id, quantity: quantity } }
    }
  end

  def stripe_embedded_checkout_test?
    %w[
      test_Stripe_embedded_checkout_mounts_transient_data_and_browser_return_cannot_fulfil_the_intent
      test_pending_Stripe_checkout_session_presents_while_provider_confirmation_remains_open
      test_pending_provider_checkout_without_a_created_session_does_not_mount_presentation
    ].include?(name)
  end

  def create_presented_checkout_intent(root, option, presentation:)
    RecordingStudioBilling.create_checkout_intent(
      root_recording: root, local_idempotency_key: "#{presentation}-#{SecureRandom.uuid}", country_code: "IT",
      presentation:, items: [{ billing_option_recording_id: option.recording.id, quantity: 1 }]
    ).intent
  end

  def use_presentation_checkout_adapter!
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider("fake", PresentationCheckoutAdapter.new)
  end

  def create_embedded_checkout_intent(quantity: 1)
    RecordingStudioBilling.create_checkout_intent(
      root_recording: @root, local_idempotency_key: "embedded-#{SecureRandom.uuid}", country_code: "IT",
      items: [{ billing_option_recording_id: @option.recording.id, quantity: }]
    ).intent
  end

  def switch_root(root)
    ensure_view_access!(root)
    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces", root_switch: { root_recording_id: root.id, return_to: "/" }
    }
    assert_response :redirect, response.body
  end

  def ensure_view_access!(root, actor: @user)
    return if RecordingStudioAccessible.authorized?(actor:, recording: root, role: :view)

    result = RecordingStudioAccessible.bootstrap_owner_access!(recording: root, actor:)
    return if result.success?

    result = RecordingStudioAccessible.grant_access(
      recording: root, actor:, role: :view, manager_actor: actor
    )
    raise result.error unless result.success?
  end

  def published_checkout_option(recurrence: "one_time", interval: nil, adapter_key: "fake", product_kind: "service", checkout_policy: "allowed", amount_minor: 1_000)
    provider_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: provider_root,
                                                        key: "billing_#{SecureRandom.hex(4)}")
    provider = record_child(
      RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: admin.recording,
                                                  key: "provider_#{SecureRandom.hex(4)}", adapter_key:, name: adapter_key.titleize, environment: "test", configuration: {}, capabilities: [], supported_markets: ["IT"], supported_currencies: ["EUR"]), provider_root, admin.recording
    )
    market = record_child(
      RecordingStudioBilling::Market.new(provider_account_recording: provider, key: "market_#{SecureRandom.hex(4)}",
                                         country_codes: ["IT"], country_groups: {}, regional_country_codes: [], global_fallback: false, allowed_currency_codes: ["EUR"], default_currency_code: "EUR", priority: 1, specificity: 1, ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive", verification_policy: "requote"), provider_root, admin.recording
    )
    product = record_child(
      RecordingStudioBilling::Product.new(provider_account_recording: provider, key: "product_#{SecureRandom.hex(4)}",
                                          kind: product_kind, feature_values: {}), provider_root, admin.recording
    )
    option_recording = record_child(
      RecordingStudioBilling::BillingOption.new(product_recording: product, key: "option_#{SecureRandom.hex(4)}",
                                                recurrence:, interval:, interval_count: interval && 1, quantity_mode: "adjustable", minimum_quantity: 1, maximum_quantity: 3, default_quantity: 1, pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0, trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy:, tax_policy: "exclusive", feature_values: {}), provider_root, product
    )
    price = record_child(
      RecordingStudioBilling::Price.new(billing_option_recording: option_recording, market_recording: market,
                                        key: "price_#{SecureRandom.hex(4)}", amount_minor:, currency_code: "EUR", currency_exponent: 2, pricing_model: "flat", version: 1, scope: "market", feature_values: {}), provider_root, option_recording
    )
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: provider_root,
                                                         price_recording_ids: [price.id], actor: @user)
    register_fake_checkout_adapter! if adapter_key == "fake" && !RecordingStudioBilling.configuration.provider_registry.registered?("fake")
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Customer #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: root, name: "Customer #{SecureRandom.hex(4)}")
    [root,
     RecordingStudio::Recording.unscoped.find(option_recording.id).recordable]
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

  def use_stripe_embedded_checkout_adapter!
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider("stripe", StripeEmbeddedCheckoutAdapter.new)
  end

  def use_pending_stripe_session_checkout_adapter!
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider("stripe", PendingStripeSessionCheckoutAdapter.new)
  end

  def use_pending_timeout_checkout_adapter!
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider("stripe", PendingTimeoutCheckoutAdapter.new)
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

  class StripeEmbeddedCheckoutAdapter < RecordingStudioBilling::FakeFinancialAdapter
    def initialize
      super(
        outcome: :success,
        capabilities: RecordingStudioBilling::ProviderCapabilities.new(
          operations: ["checkout"], currencies: ["EUR"], markets: ["IT"], collection_methods: ["automatic"],
          checkout_modes: ["embedded"], quantities: ["adjustable"], composition: ["single"]
        )
      )
    end

    def checkout_presentation(provider_reference:)
      return {} unless provider_reference == "fake-operation"

      { mode: "embedded", client_secret: "cs_test_embedded_secret", publishable_key: "pk_test_embedded" }
    end
  end

  # Mirrors StripeAdapter: session create returns pending + checkout_session_created while
  # payment confirmation is still open, leaving the intent in pending_provider.
  class PendingStripeSessionCheckoutAdapter < RecordingStudioBilling::FakeFinancialAdapter
    def initialize
      super(
        outcome: :pending,
        capabilities: RecordingStudioBilling::ProviderCapabilities.new(
          operations: ["checkout"], currencies: ["EUR"], markets: ["IT"], collection_methods: ["automatic"],
          checkout_modes: ["embedded"], quantities: ["adjustable"], composition: ["single"]
        )
      )
    end

    def call(**)
      RecordingStudioBilling::AdapterResponse.new(
        status: "pending",
        provider_reference: "cs_test_pending_session",
        result: { "checkout_session_created" => true, "presentation" => "embedded" },
        metadata: { "adapter" => "stripe" },
        uncertain_outcome: true
      )
    end

    def provider_reference_type(command:, provider_reference:)
      "checkout.session" if command.command_type == "checkout" && provider_reference.to_s.start_with?("cs_")
    end

    def checkout_presentation(provider_reference:)
      return {} unless provider_reference == "cs_test_pending_session"

      { mode: "embedded", client_secret: "cs_test_pending_secret", publishable_key: "pk_test_pending" }
    end
  end

  class PendingTimeoutCheckoutAdapter < RecordingStudioBilling::FakeFinancialAdapter
    def initialize
      super(
        outcome: :pending,
        capabilities: RecordingStudioBilling::ProviderCapabilities.new(
          operations: ["checkout"], currencies: ["EUR"], markets: ["IT"], collection_methods: ["automatic"],
          checkout_modes: ["embedded"], quantities: ["adjustable"], composition: ["single"]
        )
      )
    end

    def call(**)
      RecordingStudioBilling::AdapterResponse.new(
        status: "pending",
        result: { "reason" => "provider_timeout" },
        uncertain_outcome: true
      )
    end

    def checkout_presentation(**)
      { mode: "embedded", client_secret: "must_not_render", publishable_key: "must_not_render" }
    end
  end

  class PresentationCheckoutAdapter < RecordingStudioBilling::FakeFinancialAdapter
    def initialize
      super(
        outcome: :success,
        capabilities: RecordingStudioBilling::ProviderCapabilities.new(
          operations: ["checkout"], currencies: ["EUR"], markets: ["IT"],
          collection_methods: %w[automatic send_invoice],
          checkout_modes: %w[embedded redirect payment_link invoice no_charge],
          quantities: ["adjustable"], composition: ["single"]
        )
      )
    end

    def call(command:, request:, idempotency_key:)
      response = super
      return response unless %w[success duplicate].include?(response.status)

      presentation = command.canonical_request.dig("request", "presentation")
      RecordingStudioBilling::AdapterResponse.new(status: response.status, provider_reference: "fake-#{command.id}",
                                                  result: response.result.merge("presentation" => presentation),
                                                  metadata: response.metadata)
    end

    def checkout_presentation(provider_reference:)
      command = RecordingStudioBilling::FinancialCommand.find_by(provider_reference:)
      presentation = command&.canonical_request&.dig("request", "presentation").to_s
      case presentation
      when "redirect", "payment_link", "invoice"
        { mode: presentation, url: "https://checkout.example.test/#{presentation}" }
      when "embedded", "no_charge"
        { mode: presentation }
      else
        {}
      end
    end
  end
end
