# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require "rails/test_help"

module GatesTestCounts
  class << self
    def for(root)
      counts.fetch(root.id, 0)
    end

    def set(root, value)
      counts[root.id] = Integer(value)
    end

    def reset!
      counts.clear
    end

    private

    def counts
      @counts ||= {}
    end
  end
end

class GatesAndFreemiumTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    acquire_database_lock!
    clear_data!
    GatesTestCounts.reset!
    @actor = User.create!(email: "gates-#{SecureRandom.hex(4)}@example.com", password: "Password1!",
                          password_confirmation: "Password1!")
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    RecordingStudioBilling.configuration.default_free_plan_product_key = "free_plan"
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
    RecordingStudioBilling.configuration.billing_location_context_resolver = lambda do |**|
      { host_country: verified_country("IT", :host) }
    end
    RecordingStudioBilling.configuration.gates = {
      "projects" => {
        kind: :limit,
        label: "Projects",
        count: ->(root:) { GatesTestCounts.for(root) }
      }
    }
    RecordingStudioBilling.configuration.reset_registries!
  rescue StandardError
    clear_data! if @database_lock_held
    release_database_lock!
    raise
  end

  teardown do
    clear_data! if @database_lock_held
  ensure
    release_database_lock!
  end

  test "ensure account applies default free entitlements from published catalogue plan" do
    graph = published_free_plan_catalogue
    account = RecordingStudioBilling.ensure_account(root_recording: graph[:customer_root], name: "Customer")

    assert_equal 2, RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "projects")
    bootstrap = RecordingStudioBilling::DefaultEntitlementBootstrap.sole
    assert_equal "free_plan", bootstrap.product_key
    assert_equal account.recording.id, bootstrap.account_recording_id
    assert(account.recording.events.any? { |event| event.action == "default_free_entitlements_applied" })

    second = RecordingStudioBilling.apply_default_free_entitlements!(root_recording: graph[:customer_root])
    assert second.existing?
    assert_equal 1, RecordingStudioBilling::DefaultEntitlementBootstrap.count
  end

  test "bootstrap grants are ignored when a live subscription exists" do
    graph = published_free_plan_catalogue
    account = RecordingStudioBilling.ensure_account(root_recording: graph[:customer_root], name: "Customer")
    graph[:account_recording] = account.recording
    paid_graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month", amount: 4_900,
                                     option_feature_values: { "projects" => 10 })
    paid_graph[:customer_root] = graph[:customer_root]
    paid_graph[:account_recording] = graph[:account_recording]
    project_subscription!(paid_graph, key: "paid-plan")

    assert_equal 10, RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "projects")
  end

  test "enforce gate denies limit breaches and require gate raises" do
    graph = published_free_plan_catalogue
    RecordingStudioBilling.ensure_account(root_recording: graph[:customer_root], name: "Customer")
    GatesTestCounts.set(graph[:customer_root], 1)

    allowed = RecordingStudioBilling.enforce_gate!(root_recording: graph[:customer_root], gate_key: "projects")
    assert allowed.allowed

    GatesTestCounts.set(graph[:customer_root], 2)
    denied = RecordingStudioBilling.enforce_gate!(root_recording: graph[:customer_root], gate_key: "projects")
    refute denied.allowed
    assert_match(/limit reached/, denied.reason)

    assert_raises(RecordingStudioBilling::EnforceGate::Denied) do
      RecordingStudioBilling.require_gate!(root_recording: graph[:customer_root], gate_key: "projects")
    end
  end

  test "enforce gate accepts optional subject for child-scoped counts" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features.merge(
      "comments_per_page" => {
        source: "catalogue", merge_rule: "replace", default: 0, type: "limit", meter_key: nil,
        usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 2,
        validation: { "minimum" => 0 }
      }
    )
    RecordingStudioBilling.configuration.gates = RecordingStudioBilling.configuration.gates.merge(
      "comments_per_page" => {
        kind: :limit,
        label: "Comments",
        count: ->(root:, subject:) { root && subject.fetch(:comments) }
      }
    )
    graph = published_free_plan_catalogue(
      option_feature_values: { "projects" => 2, "comments_per_page" => 4 }
    )
    RecordingStudioBilling.ensure_account(root_recording: graph[:customer_root], name: "Customer")

    page = { comments: 3 }
    allowed = RecordingStudioBilling.enforce_gate!(
      root_recording: graph[:customer_root], gate_key: "comments_per_page", subject: page
    )
    assert allowed.allowed
    assert_equal 3, allowed.current
    assert_equal 4, allowed.limit

    page = { comments: 4 }
    denied = RecordingStudioBilling.enforce_gate!(
      root_recording: graph[:customer_root], gate_key: "comments_per_page", subject: page
    )
    refute denied.allowed

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling.enforce_gate!(root_recording: graph[:customer_root], gate_key: "comments_per_page")
    end
    assert_match(/requires subject/, error.message)
  end

  private

  def published_free_plan_catalogue(option_feature_values: { "projects" => 2 })
    published_catalogue(kind: "plan", recurrence: "recurring", interval: "month", amount: 0,
                        product_key: "free_plan", option_feature_values:, skip_account: true)
  end

  def entitlement_features
    {
      "projects" => {
        source: "catalogue", merge_rule: "replace", default: 0, type: "limit", meter_key: nil,
        usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 1,
        validation: { "minimum" => 0 }
      }
    }
  end

  def published_catalogue(kind: "service", recurrence: "one_time", interval: nil, trial_days: 0, amount: 1_000,
                          account_country: "IT", checkout_policy: "allowed", product_key: nil,
                          option_feature_values: {}, price_feature_values: {}, skip_account: false)
    provider_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: provider_root,
                                                        key: "billing_#{SecureRandom.hex(4)}")
    provider_recording = record_child(
      RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}",
                                                  adapter_key: "fake", name: "Fake", environment: "test", configuration: {}, capabilities: [], supported_markets: %w[IT DE], supported_currencies: ["EUR"]),
      provider_root, admin.recording
    )
    italy_market = market("italy", "IT", provider_recording, provider_root, admin.recording, "requote")
    germany_market = market("germany", "DE", provider_recording, provider_root, admin.recording, "requote")
    graph = { provider_root:, admin:, provider_recording:, italy_market:, germany_market: }
    option, published_italy_price, = published_option(graph, kind:, recurrence:, interval:, trial_days:, amount:,
                                                             checkout_policy:, product_key:, option_feature_values:,
                                                             price_feature_values:)
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success,
                                                               capabilities: RecordingStudioBilling::ProviderCapabilities.new(operations: ["checkout"], currencies: ["EUR"],
                                                                                                                              markets: %w[IT DE], collection_methods: ["automatic"], checkout_modes: ["redirect"], quantities: ["fixed"], composition: ["single"]))
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider("fake", adapter)
    customer_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Customer #{SecureRandom.hex(4)}"))
    account_recording = unless skip_account
                          record_child(
                            RecordingStudioBilling::Account.new(root_recording: customer_root, name: "Customer account",
                                                                billing_country_code: account_country),
                            customer_root, customer_root
                          )
                        end
    graph.merge(customer_root:, account_recording:, option:, italy_price: published_italy_price)
  end

  def published_option(graph, kind:, recurrence:, interval:, product_recording: nil, product_key: nil, trial_days: 0,
                       amount: 1_000, option_feature_values: {}, price_feature_values: {}, checkout_policy: "allowed")
    product_recording ||= record_child(
      RecordingStudioBilling::Product.new(provider_account_recording: graph[:provider_recording],
                                          key: product_key || "product_#{SecureRandom.hex(4)}", kind:, feature_values: {}), graph[:provider_root], graph[:admin].recording
    )
    option_recording = record_child(
      RecordingStudioBilling::BillingOption.new(product_recording: product_recording, key: "option_#{SecureRandom.hex(4)}",
                                                recurrence:, interval:, interval_count: interval && 1, quantity_mode: "fixed", default_quantity: 1, pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0, trial_days:, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy:, tax_policy: "exclusive", feature_values: option_feature_values), graph[:provider_root], product_recording
    )
    RecordingStudioBilling.configuration.feature_definitions.each do |key, definition|
      record_child(
        RecordingStudioBilling::Feature.new(product_recording:, key:, kind: definition.fetch("type"),
                                            definition: {}), graph[:provider_root], product_recording
      )
    end
    italy_price = price("italy", option_recording, graph[:italy_market], amount, graph[:provider_root], price_feature_values)
    germany_price = price("germany", option_recording, graph[:germany_market], amount + 200, graph[:provider_root], price_feature_values)
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:provider_root],
                                                         price_recording_ids: [italy_price.id, germany_price.id], actor: @actor)
    [
      current_recordable(option_recording, RecordingStudioBilling::BillingOption),
      current_recordable(italy_price, RecordingStudioBilling::Price),
      current_recordable(germany_price, RecordingStudioBilling::Price)
    ]
  end

  def project_subscription!(graph, key:)
    intent = create_intent(graph, country: "IT", key:).intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                             root_recording: graph[:customer_root]).subscription
  end

  def create_intent(graph, country:, key:)
    RecordingStudioBilling.create_checkout_intent(
      root_recording: graph[:customer_root], local_idempotency_key: key, country_code: country,
      items: [{ billing_option_recording_id: graph[:option].recording.id, quantity: 1 }]
    )
  end

  def verified_country(country_code, source)
    RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new(country_code, source)
  end

  def current_recordable(recording, expected_type = nil)
    recordable = RecordingStudio::Recording.unscoped.find(recording.id).recordable
    raise "published recording has no current recordable" unless recordable
    raise "published recording has an unexpected recordable" if expected_type && !recordable.is_a?(expected_type)

    recordable
  end

  def market(key, country, provider, root, parent, verification_policy)
    record_child(
      RecordingStudioBilling::Market.new(provider_account_recording: provider, key: "#{key}_market",
                                         country_codes: [country], country_groups: {}, regional_country_codes: [], global_fallback: false, allowed_currency_codes: ["EUR"], default_currency_code: "EUR", priority: 10, specificity: 1, ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive", verification_policy:), root, parent
    )
  end

  def price(key, option, market, amount, root, feature_values = {})
    record_child(
      RecordingStudioBilling::Price.new(billing_option_recording: option, market_recording: market, key: "#{key}_price",
                                        amount_minor: amount, currency_code: "EUR", currency_exponent: 2, pricing_model: "flat", version: 1, scope: "market", feature_values:), root, option
    )
  end

  def record_child(recordable, root, parent)
    RecordingStudio::Recording.unscoped.find(RecordingStudio.record!(action: "created", recordable:,
                                                                     root_recording: root, parent_recording: parent).recording.id)
  end

  def clear_data!
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
