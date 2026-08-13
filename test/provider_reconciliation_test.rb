# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require "rails/test_help"
require "recording_studio_webhooks"

class ProviderReconciliationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  class Adapter
    attr_reader :idempotency_keys, :retrieval_calls, :verification_calls

    def initialize(verification: :trusted, outcome: "succeeded")
      @verification = verification
      @outcomes = Array(outcome)
      @idempotency_keys = []
      @retrieval_calls = 0
      @verification_calls = 0
    end

    def capabilities
      RecordingStudioBilling::ProviderCapabilities.new(
        operations: ["checkout"], currencies: ["EUR"], markets: ["IT"], collection_methods: ["automatic"],
        checkout_modes: %w[embedded redirect], tax_modes: ["provider"], quantities: ["fixed"], composition: ["single"]
      )
    end

    def call(command:, request:, idempotency_key:)
      @idempotency_keys << idempotency_key
      RecordingStudioBilling::AdapterResponse.new(status: "pending", provider_reference: "cs_#{command.operation_id.delete('-')}",
                                                  result: { "checkout_session_created" => true }, uncertain_outcome: true)
    end

    def verify_webhook(**attributes)
      @verification_calls += 1
      raise ArgumentError, "verification failed" unless @verification == :trusted

      attributes.slice(:provider_account_recording_id, :environment, :event_id, :remote_type, :remote_id)
    end

    def retrieve(command:)
      @retrieval_calls += 1
      outcome = @outcomes.length > 1 ? @outcomes.shift : @outcomes.first
      raise ArgumentError, "retrieval unavailable" if outcome == :unavailable

      payload = outcome.to_s == "succeeded" && command.command_type == "checkout" ? checkout_payload(command) : { "status" => outcome.to_s }
      { outcome: outcome.to_s, remote_type: command.command_type == "checkout" ? "checkout.session" : "operation",
        remote_id: command.provider_reference, payload: }
    end

    def provider_reference_type(command:, provider_reference:)
      "checkout.session" if command.command_type == "checkout" && provider_reference.start_with?("cs_")
    end

    private

    def checkout_payload(command)
      intent = RecordingStudioBilling::CheckoutIntent.find_by!(financial_command: command)
      item = intent.items.sole
      amount = item.commercial_manifest.dig("canonical_data", "price", "amount_minor") * item.quantity
      tax_policy = command.canonical_request.dig("request", "tax").to_h
      tax = tax_policy["enabled"] ? 90 : 0
      payload = { "subtotal_minor" => amount, "discount_minor" => 0, "tax_minor" => tax, "total_minor" => amount + tax,
                  "currency" => item.currency_code, "payment_state" => "paid",
                  "lines" => [{ "checkout_intent_item_id" => item.id, "manifest_digest" => item.manifest_digest,
                                "currency" => item.currency_code, "quantity" => item.quantity, "unit_amount_minor" => amount / item.quantity,
                                "subtotal_minor" => amount, "discount_minor" => 0, "tax_minor" => tax, "total_minor" => amount + tax }] }
      return payload unless tax_policy["enabled"]

      payload.merge("behavior" => tax_policy.fetch("behavior"), "breakdown" => [{ "category" => "provider", "amount_minor" => tax }],
                    "calculator_reference" => command.provider_reference, "calculated_at" => Time.current.iso8601(6))
    end
  end

  setup do
    BillingTestDatabaseCleanup.clear!
    RecordingStudioBilling.configuration.reset_registries!
  end

  teardown do
    BillingTestDatabaseCleanup.clear!
    RecordingStudioBilling.configuration.reset_registries!
  end

  test "trusted receipt effects are scoped by provider account and terminal replay is projection-safe" do
    adapter = Adapter.new
    RecordingStudioBilling.register_provider(:provider_reconciliation, adapter)
    first = real_checkout(adapter_key: "provider_reconciliation")
    second = real_checkout(adapter_key: "provider_reconciliation")

    first_result = dispatch_webhook(first, event_id: "evt_shared")
    duplicate = dispatch_webhook(first,
                      inbound_event: RecordingStudioWebhooks::InboundEvent.find(first_result.effect.inbound_event_id), event_id: "evt_shared")
    second_result = dispatch_webhook(second, event_id: "evt_shared")
    distinct_terminal = dispatch_webhook(first, event_id: "evt_other")
    versioned = dispatch_webhook(first,
                      inbound_event: RecordingStudioWebhooks::InboundEvent.find(first_result.effect.inbound_event_id), event_id: "evt_shared", action_version: "v2")

    assert first_result.accepted?
    assert duplicate.accepted?
    assert_equal first_result.effect.id, duplicate.effect.id
    assert second_result.accepted?
    assert distinct_terminal.accepted?
    assert versioned.accepted?
    assert_equal "succeeded", first.command.reload.state
    assert_equal "succeeded", second.command.reload.state
    assert_equal "completed", first.intent.reload.state
    assert_equal 1, RecordingStudioBilling::SubscriptionItemVersion.where(checkout_intent: first.intent).count
    assert_equal 4, RecordingStudioBilling::WebhookEffect.count
    assert_equal 2, RecordingStudioBilling::ReconciliationRecord.count
  end

  test "pending Checkout Session correlates a trusted paid webhook and projects native tax once" do
    RecordingStudioBilling.configuration.billing_location_context_resolver = lambda do |**|
      { host_country: RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("IT", :host) }
    end
    RecordingStudioBilling.configuration.tax_policy = { enabled: true, calculator_key: "stripe_tax",
                                                        presentation: "exclusive", semantic_categories: ["standard"], location_requirements: [] }
    adapter = Adapter.new
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider(:stripe, adapter)
    checkout = real_checkout(adapter_key: "stripe")

    assert_equal "requires_reconciliation", checkout.command.reload.state
    assert RecordingStudioBilling::ProviderReference.exists?(financial_command: checkout.command,
                                                             remote_type: "checkout.session", remote_id: checkout.command.provider_reference)
    result = dispatch_webhook(checkout, event_id: "evt_paid")
    replay = dispatch_webhook(checkout, inbound_event: RecordingStudioWebhooks::InboundEvent.find(result.effect.inbound_event_id),
                             event_id: "evt_paid")

    assert result.accepted?
    assert_equal result.effect.id, replay.effect.id
    assert_equal 1, RecordingStudioBilling::TaxCalculation.where(financial_command: checkout.command).count
    assert_equal 1, RecordingStudioBilling::Invoice.where(financial_command: checkout.command).count
    assert_equal 1, RecordingStudioBilling::Payment.where(financial_command: checkout.command).count
    assert_equal "completed", checkout.intent.reload.state
  end

  test "unknown reference and failed verification are rejected with scoped safe diagnostics" do
    trusted = Adapter.new
    RecordingStudioBilling.register_provider(:provider_reconciliation, trusted)
    command = reconciliable_command(adapter_key: "provider_reconciliation", environment: "production")

    unknown_receipt = receipt_for(command, event_id: "evt_unknown", remote_id: "missing")
    unknown = RecordingStudioBilling.apply_provider_webhook(
      inbound_event: unknown_receipt, remote_type: "operation", remote_id: "missing"
    )
    assert unknown.rejected?

    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.register_provider(:provider_reconciliation, Adapter.new(verification: :rejected))
    rejected = dispatch_webhook(command, event_id: "evt_rejected")
    assert rejected.rejected?

    issues = RecordingStudioBilling::ReconciliationIssue.where(financial_command_id: nil).order(:created_at)
    assert_equal %w[provider_verification_rejected unknown_provider_reference], issues.pluck(:kind).sort
    issues.each do |issue|
      assert_equal command.provider_account_recording.id, issue.provider_account_recording_id
      assert_equal "production", issue.environment
      assert_equal({}, issue.safe_payload)
    end
  end

  test "fabricated receipts are rejected before provider work" do
    adapter = Adapter.new
    RecordingStudioBilling.register_provider(:provider_reconciliation, adapter)

    result = RecordingStudioBilling.apply_provider_webhook(
      inbound_event: Struct.new(:id).new(SecureRandom.uuid), remote_type: "operation", remote_id: "operation_123"
    )

    assert result.rejected?
    assert_equal 0, adapter.verification_calls
    assert_equal 0, adapter.retrieval_calls
    assert_equal 0, RecordingStudioBilling::ReconciliationIssue.count
  end

  test "unavailable and unknown retrieval retries reuse reconciliation history before succeeding" do
    unavailable = Adapter.new(outcome: %i[unavailable unavailable succeeded])
    unknown = Adapter.new(outcome: %w[unknown unknown succeeded])
    RecordingStudioBilling.register_provider(:provider_reconciliation, unavailable)
    unavailable_command = reconciliable_command(adapter_key: "provider_reconciliation",
                                                environment: "production").command

    2.times { RecordingStudioBilling.reconcile_provider_command(command: unavailable_command) }
    assert_equal "requires_reconciliation", unavailable_command.reload.state
    assert_equal 1, RecordingStudioBilling::ReconciliationRecord.where(financial_command: unavailable_command).count
    RecordingStudioBilling.reconcile_provider_command(command: unavailable_command)
    assert_equal 3, unavailable.retrieval_calls
    assert_equal "succeeded", unavailable_command.reload.state
    assert_equal 1, RecordingStudioBilling::ReconciliationRecord.where(financial_command: unavailable_command).count

    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.register_provider(:provider_reconciliation, unknown)
    unknown_command = reconciliable_command(adapter_key: "provider_reconciliation", environment: "production").command
    2.times { RecordingStudioBilling.reconcile_provider_command(command: unknown_command) }
    assert_equal "requires_reconciliation", unknown_command.reload.state
    assert_equal 1, RecordingStudioBilling::ReconciliationRecord.where(financial_command: unknown_command).count
    RecordingStudioBilling.reconcile_provider_command(command: unknown_command)
    assert_equal "succeeded", unknown_command.reload.state
    assert_equal 1, RecordingStudioBilling::ReconciliationRecord.where(financial_command: unknown_command).count
  end

  private

  def dispatch_webhook(command, event_id:, inbound_event: nil, action_version: RecordingStudioBilling::ApplyVerifiedProviderWebhook::ACTION_VERSION)
    financial_command = command.command
    RecordingStudioBilling.apply_provider_webhook(
      inbound_event: inbound_event || receipt_for(command, event_id:), remote_type: financial_command.command_type == "checkout" ? "checkout.session" : "operation",
      remote_id: financial_command.provider_reference, action_version:
    )
  end

  def receipt_for(command, event_id:, remote_id: command.command.provider_reference)
    endpoint = RecordingStudioWebhooks::EndpointLifecycle.create!(
      endpoint: RecordingStudioWebhooks::Endpoint.new(
        recording_studio_recording_id: command.command.root_recording_id, label: "Billing receipt #{SecureRandom.hex(4)}",
        provider_name: command.command.provider_adapter_key,
        identity: {
          "billing_provider_adapter_key" => command.command.provider_adapter_key,
          "billing_provider_account_recording_id" => command.provider_account_recording.id,
          "billing_environment" => "production"
        }, metadata: {}, policy_overrides: {}
      ), actor: nil
    )
    issuance = endpoint.issue_token!
    payload = { "id" => event_id, "data" => { "object" => { "id" => remote_id, "object" => "operation" } } }
    RecordingStudioWebhooks::InboundEvent.create!(
      endpoint:, endpoint_token: issuance.endpoint_token, provider_name: endpoint.provider_name,
      event_type: "checkout.completed", provider_event_id: event_id, payload_digest: "a" * 64,
      deduplication_key: SecureRandom.uuid, payload:, provenance: {}, endpoint_snapshot: endpoint.snapshot,
      token_snapshot: issuance.endpoint_token.snapshot, policy_snapshot: {}, received_at: Time.current, status: "accepted"
    )
  end

  def reconciliable_command(adapter_key:, environment:)
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Webhook root #{SecureRandom.hex(4)}"))
    account = RecordingStudioBilling.ensure_account(root_recording: root, name: "Billing")
    admin_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider root #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: admin_root, key: "billing")
    provider = RecordingStudio.record!(
      action: "created",
      recordable: RecordingStudioBilling::ProviderAccount.new(
        billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}", adapter_key:,
        name: "Provider", environment:, configuration: {}, capabilities: [], supported_markets: [], supported_currencies: []
      ), root_recording: admin_root, parent_recording: admin.recording
    ).recording
    command = RecordingStudioBilling.create_financial_command(
      root_recording: root, account_recording: account.recording, command_type: "provider_contract",
      provider_account_recording: provider, provider_adapter_key: adapter_key,
      local_idempotency_key: SecureRandom.uuid, request: { "amount_minor" => 100, "currency" => "USD" }
    ).command
    command.update!(state: "requires_reconciliation", reconciliation_state: "pending",
                    provider_reference: "operation_#{SecureRandom.hex(8)}")
    RecordingStudioBilling::ProviderReference.create!(
      financial_command: command, provider_account_recording: provider, provider_adapter_key: adapter_key,
      environment:, remote_type: "operation", remote_id: command.provider_reference,
      reference: command.provider_reference, reference_type: "operation"
    )
    Struct.new(:command, :provider_account_recording).new(command, provider)
  end

  def real_checkout(adapter_key:)
    actor = User.create!(email: "webhook-#{SecureRandom.hex(4)}@example.test", password: "Password1!",
                         password_confirmation: "Password1!")
    provider_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: provider_root,
                                                        key: "billing_#{SecureRandom.hex(4)}")
    provider = record_child(
      RecordingStudioBilling::ProviderAccount.new(
        billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}", adapter_key:, name: "Provider",
        environment: "production", configuration: {}, capabilities: [], supported_markets: ["IT"], supported_currencies: ["EUR"]
      ), provider_root, admin.recording
    )
    market = record_child(RecordingStudioBilling::Market.new(
                            provider_account_recording: provider, key: "it", country_codes: ["IT"], country_groups: {}, regional_country_codes: [], global_fallback: false,
                            allowed_currency_codes: ["EUR"], default_currency_code: "EUR", priority: 1, specificity: 1, ppa_policy: "standard",
                            rounding_policy: "half_up", tax_presentation_policy: "exclusive", verification_policy: "none"
                          ), provider_root, admin.recording)
    product = record_child(
      RecordingStudioBilling::Product.new(provider_account_recording: provider, key: "product", kind: "plan",
                                          feature_values: {}), provider_root, admin.recording
    )
    option = record_child(RecordingStudioBilling::BillingOption.new(
                            product_recording: product, key: "plan", recurrence: "recurring", interval: "month", interval_count: 1, quantity_mode: "fixed",
                            default_quantity: 1, pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0, trial_days: 0,
                            proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive", feature_values: {}
                          ), provider_root, product)
    price = record_child(RecordingStudioBilling::Price.new(
                           billing_option_recording: option, market_recording: market, key: "price", amount_minor: 1_000, currency_code: "EUR",
                           currency_exponent: 2, pricing_model: "flat", version: 1, scope: "default", feature_values: {}
                         ), provider_root, option)
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: provider_root,
                                                         price_recording_ids: [price.id], actor:)
    option = RecordingStudioBilling::BillingOption.with_current_recording.find_by!(key: option.recordable.key).recording
    customer_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Customer #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: customer_root, name: "Billing")
    intent = RecordingStudioBilling.create_checkout_intent(
      root_recording: customer_root, local_idempotency_key: SecureRandom.uuid, country_code: "IT",
      items: [{ billing_option_recording_id: option.id, quantity: 1 }]
    ).intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: customer_root)
    command = intent.reload.financial_command.reload
    Struct.new(:command, :provider_account_recording, :intent).new(command, provider, intent)
  end

  def record_child(recordable, root, parent)
    RecordingStudio.record!(action: "created", recordable:, root_recording: root, parent_recording: parent).recording
  end
end
