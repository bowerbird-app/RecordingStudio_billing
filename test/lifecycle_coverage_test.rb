# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"
require "recording_studio_webhooks"

class LifecycleCoverageTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    BillingTestDatabaseCleanup.clear!
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
  end

  teardown do
    BillingTestDatabaseCleanup.clear!
    RecordingStudioBilling.configuration.reset_registries!
  end

  test "refunds normalize the root, reserve captured value, and reject material conflicts" do
    root, account, command = command_authority
    payment = insert_payment(root:, account:, command:)
    other_root, = account_authority

    created = RecordingStudioBilling::CreateRefundIntent.call(
      payment:, root_recording: account.recording, local_idempotency_key: "refund-key", amount_minor: 60,
      actor_reference: "admin-1", reason: "customer request", line_allocation: { "payment" => payment.id }
    )
    existing = RecordingStudioBilling::CreateRefundIntent.call(
      payment:, root_recording: root, local_idempotency_key: "refund-key", amount_minor: 60,
      actor_reference: "admin-1", reason: "customer request", line_allocation: { "payment" => payment.id }
    )

    assert created.created?
    assert existing.existing?
    assert_equal created.intent.id, existing.intent.id
    assert_equal root.id, created.intent.root_recording_id
    assert_equal 60, created.intent.amount_minor
    conflict = RecordingStudioBilling::CreateRefundIntent.call(
      payment:, root_recording: root, local_idempotency_key: "refund-key", amount_minor: 59,
      actor_reference: "admin-1", reason: "customer request", line_allocation: { "payment" => payment.id }
    )
    assert conflict.conflict?
    assert_equal created.intent.id, conflict.intent.id
    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioBilling::CreateRefundIntent.call(
        payment:, root_recording: other_root, local_idempotency_key: "refund-cross-root", amount_minor: 1,
        actor_reference: "admin-1", reason: "customer request", line_allocation: { "payment" => payment.id }
      )
    end
    assert_raises(ArgumentError) do
      RecordingStudioBilling::CreateRefundIntent.call(
        payment:, root_recording: root, local_idempotency_key: "refund-too-large", amount_minor: 41,
        actor_reference: "admin-1", reason: "customer request", line_allocation: { "payment" => payment.id }
      )
    end
    stale_root, stale_account, stale_command = command_authority
    stale = insert_payment(root: stale_root, account: stale_account, command: stale_command, state: "captured")
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CreateRefundIntent.call(
        payment: stale, root_recording: stale_root, local_idempotency_key: "refund-captured", amount_minor: 1,
        actor_reference: "admin-1", reason: "customer request", line_allocation: { "payment" => stale.id }
      )
    end
    assert_match(/not paid/, error.message)
  end

  test "adjustments bind credits to their root and reject material conflicts" do
    root, account, command = command_authority
    invoice = insert_invoice(root:, account:, command:)
    other_root, = account_authority

    created = RecordingStudioBilling::CreateAdjustmentIntent.call(
      invoice:, root_recording: root, local_idempotency_key: "credit-key", kind: "credit", amount_minor: 80,
      actor_reference: "admin-1", reason: "billing correction", affected_reference: { "invoice" => invoice.id }
    )
    existing = RecordingStudioBilling::CreateAdjustmentIntent.call(
      invoice:, root_recording: root, local_idempotency_key: "credit-key", kind: "credit", amount_minor: 80,
      actor_reference: "admin-1", reason: "billing correction", affected_reference: { "invoice" => invoice.id }
    )

    assert created.created?
    assert existing.existing?
    assert_equal created.intent.id, existing.intent.id
    conflict = RecordingStudioBilling::CreateAdjustmentIntent.call(
      invoice:, root_recording: root, local_idempotency_key: "credit-key", kind: "credit", amount_minor: 79,
      actor_reference: "admin-1", reason: "billing correction", affected_reference: { "invoice" => invoice.id }
    )
    assert conflict.conflict?
    assert_equal created.intent.id, conflict.intent.id
    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioBilling::CreateAdjustmentIntent.call(
        invoice:, root_recording: other_root, local_idempotency_key: "credit-cross-root", kind: "credit", amount_minor: 1,
        actor_reference: "admin-1", reason: "billing correction", affected_reference: { "invoice" => invoice.id }
      )
    end
    assert_raises(ArgumentError) do
      RecordingStudioBilling::CreateAdjustmentIntent.call(
        invoice:, root_recording: root, local_idempotency_key: "credit-too-large", kind: "credit", amount_minor: 21,
        actor_reference: "admin-1", reason: "billing correction", affected_reference: { "invoice" => invoice.id }
      )
    end
    assert_raises(ArgumentError) do
      RecordingStudioBilling::CreateAdjustmentIntent.call(
        invoice:, root_recording: root, local_idempotency_key: "debit-without-actor", kind: "debit", amount_minor: 1
      )
    end

    debit = RecordingStudioBilling::CreateAdjustmentIntent.call(
      invoice:, root_recording: root, local_idempotency_key: "debit-authorized", kind: "debit", amount_minor: 15,
      actor_reference: "admin-1", reason: "approved correction", affected_reference: { "invoice_line" => "line-1" }
    )
    assert debit.created?
    assert_equal "host_authorizer", debit.intent.approved_authority.fetch("source")
  end

  test "refund and adjustment projections require matching successful provider authority" do
    root, account, command = command_authority
    payment = insert_payment(root:, account:, command:)
    refund_intent = RecordingStudioBilling::CreateRefundIntent.call(
      payment:, root_recording: root, local_idempotency_key: "project-refund", amount_minor: 25,
      actor_reference: "admin-1", reason: "customer request", line_allocation: { "payment" => payment.id }
    ).intent
    complete_projection_command!(refund_intent.financial_command, status: "success", amount_minor: 25, currency: "USD",
                                                                  payment_id: payment.id)

    refund = RecordingStudioBilling::ProjectRefundIntent.call(refund_intent:, root_recording: root)
    assert_equal refund.id, RecordingStudioBilling::ProjectRefundIntent.call(refund_intent:, root_recording: root).id
    assert_equal 1, RecordingStudioBilling::Refund.count
    assert_raises(ActiveRecord::StatementInvalid) { refund.update!(amount_minor: 26) }
    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioBilling::ProjectRefundIntent.call(refund_intent:, root_recording: account_authority.first)
    end

    invoice = insert_invoice(root:, account:, command:)
    adjustment_intent = RecordingStudioBilling::CreateAdjustmentIntent.call(
      invoice:, root_recording: root, local_idempotency_key: "project-adjustment", kind: "credit", amount_minor: 15,
      actor_reference: "admin-1", reason: "billing correction", affected_reference: { "invoice" => invoice.id }
    ).intent
    complete_projection_command!(adjustment_intent.financial_command, status: "success", kind: "credit", amount_minor: 15,
                                                                      currency: "USD", invoice_id: invoice.id)

    adjustment = RecordingStudioBilling::ProjectAdjustmentIntent.call(adjustment_intent:, root_recording: root)
    assert_equal adjustment.id,
                 RecordingStudioBilling::ProjectAdjustmentIntent.call(adjustment_intent:, root_recording: root).id
    assert_equal 1, RecordingStudioBilling::FinancialAdjustment.count
  end

  test "projection mismatches and non-successful commands reconcile without financial projections" do
    root, account, command = command_authority
    payment = insert_payment(root:, account:, command:)
    intent = RecordingStudioBilling::CreateRefundIntent.call(
      payment:, root_recording: root, local_idempotency_key: "refund-mismatch", amount_minor: 20,
      actor_reference: "admin-1", reason: "customer request", line_allocation: { "payment" => payment.id }
    ).intent
    complete_projection_command!(intent.financial_command, status: "success", amount_minor: 19, currency: "USD",
                                                           payment_id: payment.id)

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::ProjectRefundIntent.call(refund_intent: intent, root_recording: root)
    end
    assert_match(/reconciliation/, error.message)
    assert_equal 0, RecordingStudioBilling::Refund.count
    assert_equal "provider_result_mismatch", RecordingStudioBilling::ReconciliationIssue.sole.kind

    intent.financial_command.update!(state: "failed")
    assert_raises(ArgumentError) { RecordingStudioBilling::ProjectRefundIntent.call(refund_intent: intent, root_recording: root) }
  end

  test "subscription changes reject quantities without a server-resolved commercial selection" do
    root, account = account_authority
    _provider_root, _admin, provider = provider_catalogue_authority
    market = provider_market(provider)
    subscription = subscription_for(root:, account:, provider:, market:).recordable

    assert_raises(ArgumentError) do
      RecordingStudioBilling::CreateSubscriptionChangeIntent.call(
        subscription:, root_recording: account.recording, local_idempotency_key: "change-key",
        change_kind: "quantity", change_set: { quantity: 2 }
      )
    end

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CreateSubscriptionChangeIntent.call(
        subscription:, root_recording: account.recording, local_idempotency_key: "customer-plan-update-fields",
        change_kind: "plan", change_set: { replacement_manifest_digest: SecureRandom.hex(32), allowance_policy: "preserve" }
      )
    end
    assert_match(/unsupported input/, error.message)
  end

  test "plan updates create a preview before a matching confirmation advances the run" do
    provider_root, admin, provider = provider_catalogue_authority
    manifest = used_manifest(root: provider_root)
    product = RecordingStudio.record!(
      action: "created",
      recordable: RecordingStudioBilling::Product.new(
        provider_account_recording: provider, key: "product_#{SecureRandom.hex(4)}", name: "Lifecycle service",
        kind: "service", feature_values: {}
      ), root_recording: provider_root, parent_recording: admin
    ).recording
    option = RecordingStudio.record!(
      action: "created",
      recordable: RecordingStudioBilling::BillingOption.new(
        product_recording: product, key: "plan_#{SecureRandom.hex(4)}", name: "Monthly",
        recurrence: "recurring", interval: "month", interval_count: 1,
        quantity_mode: "fixed", default_quantity: 1, pricing_model: "flat", collection_method: "automatic",
        payment_terms_days: 0, trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate",
        checkout_policy: "allowed", tax_policy: "exclusive"
      ), root_recording: provider_root, parent_recording: product
    ).recording
    update = RecordingStudio.record!(
      action: "created",
      recordable: RecordingStudioBilling::PlanUpdate.new(
        billing_option_recording: option, key: "update_#{SecureRandom.hex(4)}", allowance_policy: "preserve",
        execution_state: "draft", replacement_manifest_digest: manifest.manifest_digest,
        replacement_configuration: { "audience" => { "root_recording_ids" => [SecureRandom.uuid] } }
      ), root_recording: provider_root, parent_recording: admin
    ).recording.recordable

    preview = RecordingStudioBilling::ApplyPlanUpdate.call(
      plan_update: update, root_recording: provider_root, idempotency_key: "run-key"
    )
    confirmed = RecordingStudioBilling::ApplyPlanUpdate.call(
      run: preview, root_recording: provider_root, idempotency_key: "run-key", confirmation: { approved: true }
    )

    assert_equal "awaiting_confirmation", preview.state
    assert_equal manifest.manifest_digest, preview.preview.fetch("replacement_manifest_digest")
    assert_equal preview.id, confirmed.id
    assert_equal({ "approved" => true }, confirmed.confirmation)
    assert_equal "applying", confirmed.state
  end

  test "a confirmed future plan update remains scheduled until it is due" do
    provider_root, _admin, provider = provider_catalogue_authority
    customer_root, = account_authority
    update = plan_update_for(provider_root:, provider:, audience_root_ids: [customer_root.id],
                             effective_at: 1.hour.from_now)

    preview = RecordingStudioBilling::ApplyPlanUpdate.call(
      plan_update: update, root_recording: provider_root, idempotency_key: "scheduled-run"
    )
    scheduled = RecordingStudioBilling::ApplyPlanUpdate.call(
      run: preview, root_recording: provider_root, idempotency_key: "scheduled-run",
      confirmation: { "approved_by" => "admin-1" }
    )

    assert_equal "scheduled", scheduled.state
    assert_equal({ "approved_by" => "admin-1" }, scheduled.confirmation)
    assert_empty scheduled.applications
  end

  test "plan update preflight blocks every subscription when one provider command requires review" do
    root, account, capture_command = command_authority
    provider = capture_command.provider_account_recording
    provider_root = provider.root_recording
    market = provider_market(provider)
    second_root, second_account = account_authority
    first_subscription = subscription_for(root:, account:, provider:, market:)
    second_subscription = subscription_for(root: second_root, account: second_account, provider:, market:)
    update = plan_update_for(provider_root:, provider:, audience_root_ids: [root.id, second_root.id])
    run = update.runs.create!(idempotency_key: "atomic-run", request_fingerprint: "a" * 64,
                              confirmation: { "approved_by" => "admin-1" }, preview: {}, reconciliation: {}, state: "applying")
    ready_intent = subscription_change_intent_for(first_subscription)
    review_command = RecordingStudioBilling.create_financial_command(
      root_recording: second_root, account_recording: second_account.recording, command_type: "subscription_change",
      local_idempotency_key: "review-command", provider_account_recording: provider, provider_adapter_key: "test", request: {}
    ).command
    review_command.update!(state: "requires_reconciliation")
    review_intent = subscription_change_intent_for(second_subscription, financial_command: review_command)
    RecordingStudioBilling::PlanUpdateApplication.create!(plan_update: update, plan_update_run: run,
                                                          subscription_recording: first_subscription, subscription_change_intent: ready_intent, state: "pending")
    RecordingStudioBilling::PlanUpdateApplication.create!(plan_update: update, plan_update_run: run,
                                                          subscription_recording: second_subscription, subscription_change_intent: review_intent, state: "pending")

    RecordingStudioBilling::ApplyPlanUpdate.call(run:, root_recording: provider_root,
                                                 idempotency_key: run.idempotency_key)

    assert_equal "requires_review", run.reload.state
    assert_equal "pending_provider", ready_intent.reload.state
    assert_equal "requires_review", run.applications.find_by(subscription_recording: second_subscription).state
    assert_equal 0,
                 RecordingStudioBilling::SubscriptionLine.where(
                   subscription_recording_id: [first_subscription.id, second_subscription.id]
                 ).count
  end

  test "provider references and webhook effects enforce versioned provider identity" do
    root, account, command = command_authority
    provider_reference = RecordingStudioBilling::ProviderReference.create!(
      financial_command: command, provider_account_recording: command.provider_account_recording,
      provider_adapter_key: "test", environment: "test", remote_type: "payment", remote_id: "remote-1",
      reference: "remote-1", reference_type: "payment"
    )
    invalid = provider_reference.dup
    invalid.remote_id = "bad id"
    refute invalid.valid?
    assert_includes invalid.errors[:remote_id], "is invalid"
    inbound_event = trusted_inbound_event(command)

    effect = RecordingStudioBilling::WebhookEffect.create!(
      provider_adapter_key: "test", event_id: "event-1", handler_name: "billing.provider_event",
      action_version: "v1", provider_reference:, financial_command: command,
      provider_account_recording_id: command.provider_account_recording_id, environment: "test", inbound_event_id: inbound_event.id,
      safe_payload: {}, processed_at: Time.current
    )
    next_version = RecordingStudioBilling::WebhookEffect.create!(
      provider_adapter_key: "test", event_id: "event-1", handler_name: "billing.provider_event",
      action_version: "v2", provider_reference:, financial_command: command,
      provider_account_recording_id: command.provider_account_recording_id, environment: "test", inbound_event_id: inbound_event.id,
      safe_payload: {}, processed_at: Time.current
    )

    assert_raises(ActiveRecord::RecordNotUnique) do
      RecordingStudioBilling::WebhookEffect.create!(
        provider_adapter_key: "test", event_id: "event-1", handler_name: "billing.provider_event",
        action_version: "v1", provider_reference:, financial_command: command,
        provider_account_recording_id: command.provider_account_recording_id, environment: "test", inbound_event_id: inbound_event.id,
        safe_payload: {}, processed_at: Time.current
      )
    end
    assert_equal %w[v1 v2],
                 RecordingStudioBilling::WebhookEffect.where(id: [effect.id,
                                                                  next_version.id]).order(:action_version).pluck(:action_version)
    assert_equal root.id, account.recording.root_recording_id
  end

  test "provider references scope remote identities to provider account and environment" do
    _root, _account, command = command_authority
    attributes = {
      financial_command: command, provider_account_recording: command.provider_account_recording,
      provider_adapter_key: "test", environment: "test", remote_type: "payment", remote_id: "shared-remote",
      reference: "shared-remote", reference_type: "payment"
    }
    RecordingStudioBilling::ProviderReference.create!(**attributes)
    assert_raises(ActiveRecord::RecordNotUnique) { RecordingStudioBilling::ProviderReference.create!(**attributes) }

    other_root, other_account = account_authority
    _provider_root, _admin, other_provider = provider_catalogue_authority(environment: "sandbox")
    other_command = RecordingStudioBilling.create_financial_command(
      root_recording: other_root, account_recording: other_account.recording, command_type: "capture_funds",
      local_idempotency_key: SecureRandom.uuid, provider_account_recording: other_provider, provider_adapter_key: "test",
      request: { approved_amount_minor: 100 }
    ).command
    other_reference = RecordingStudioBilling::ProviderReference.create!(
      financial_command: other_command, provider_account_recording: other_provider, provider_adapter_key: "test",
      environment: "sandbox", remote_type: "payment", remote_id: "shared-remote", reference: "shared-remote", reference_type: "payment"
    )

    assert_equal other_provider.id, other_reference.provider_account_recording_id
    assert_equal "sandbox", other_reference.environment
  end

  private

  def account_authority
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Lifecycle #{SecureRandom.hex(4)}"))
    account = RecordingStudioBilling.ensure_account(root_recording: root, name: "Billing")
    [root, account]
  end

  def command_authority
    root, account = account_authority
    command = RecordingStudioBilling.create_financial_command(
      root_recording: root, account_recording: account.recording, command_type: "capture_funds",
      local_idempotency_key: SecureRandom.uuid, provider_account_recording: provider_catalogue_authority.last,
      provider_adapter_key: "test", request: { approved_amount_minor: 100 }
    ).command
    [root, account, command]
  end

  def provider_catalogue_authority(environment: "test")
    root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: root, key: "billing")
    provider = RecordingStudio.record!(
      action: "created",
      recordable: RecordingStudioBilling::ProviderAccount.new(
        billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}", adapter_key: "test",
        name: "Provider", environment:, configuration: {}, capabilities: [], supported_markets: [], supported_currencies: []
      ), root_recording: root, parent_recording: admin.recording
    ).recording
    [root, admin.recording, provider]
  end

  def used_manifest(root:)
    data = { "fixture" => true }
    snapshots = [{ "recording_id" => root.id }]
    references = { "root" => { "recording_id" => root.id } }
    envelope = {
      "schema_version" => "v1", "resolver_version" => "v1", "root_recording_id" => root.id,
      "canonical_data" => data, "recording_snapshots" => snapshots, "snapshot_references" => references
    }
    RecordingStudioBilling::CommercialManifest.create!(
      root_recording_id: root.id, schema_version: "v1", resolver_version: "v1", canonical_data: data,
      recording_snapshots: snapshots, snapshot_references: references,
      manifest_digest: RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope), used_at: Time.current
    )
  end

  def plan_update_for(provider_root:, provider:, audience_root_ids:, effective_at: nil)
    admin = provider.parent_recording
    product = RecordingStudio.record!(
      action: "created", recordable: RecordingStudioBilling::Product.new(
        provider_account_recording: provider, key: "product_#{SecureRandom.hex(4)}", name: "Lifecycle service",
        kind: "service", feature_values: {}
      ), root_recording: provider_root, parent_recording: admin
    ).recording
    option = RecordingStudio.record!(
      action: "created", recordable: RecordingStudioBilling::BillingOption.new(
        product_recording: product, key: "plan_#{SecureRandom.hex(4)}", name: "Monthly",
        recurrence: "recurring", interval: "month", interval_count: 1,
        quantity_mode: "fixed", default_quantity: 1, pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0,
        trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"
      ), root_recording: provider_root, parent_recording: product
    ).recording
    manifest = used_manifest(root: provider_root)
    RecordingStudio.record!(
      action: "created", recordable: RecordingStudioBilling::PlanUpdate.new(
        billing_option_recording: option, key: "update_#{SecureRandom.hex(4)}", allowance_policy: "preserve", execution_state: "draft",
        replacement_manifest_digest: manifest.manifest_digest,
        replacement_configuration: { "audience" => { "root_recording_ids" => audience_root_ids }, "effective_at" => effective_at&.iso8601 }
      ), root_recording: provider_root, parent_recording: admin
    ).recording.recordable
  end

  def subscription_for(root:, account:, provider:, market:)
    root.record(RecordingStudioBilling::Subscription, parent_recording: account.recording) do |subscription|
      subscription.assign_attributes(subscription_attributes(root:, account:, provider:, market:))
    end
  end

  def subscription_attributes(root:, account:, provider:, market:)
    identity = { provider_account_recording_id: provider.id, market_recording_id: market.id, currency_code: "USD",
                 collection_method: "automatic", billing_anchor: "checkout", payment_terms_days: 0 }
    identity.merge(
      root_recording: root, account_recording: account.recording, identifier: SecureRandom.uuid, state: "active",
      provider_reference: "subscription-#{SecureRandom.uuid}",
      execution_group_fingerprint: RecordingStudioBilling::Subscription.execution_group_fingerprint(identity)
    )
  end

  def subscription_change_intent_for(subscription_recording, financial_command: nil)
    subscription = subscription_recording.recordable
    RecordingStudioBilling::SubscriptionChangeIntent.create!(
      subscription_recording:, root_recording: subscription.root_recording,
      account_recording: subscription.account_recording,
      financial_command:, local_idempotency_key: SecureRandom.uuid, request_fingerprint: "a" * 64, change_kind: "plan",
      change_set: {}, frozen_terms: {}, timing: "immediate", proration_policy: "none", state: "pending_provider"
    )
  end

  def insert_payment(root:, account:, command:, state: "paid")
    now = Time.current
    id = SecureRandom.uuid
    RecordingStudioBilling::Payment.insert_all!([{
                                                  id:, root_recording_id: root.id, account_recording_id: account.recording.id, financial_command_id: command.id,
                                                  provider_reference: "payment-#{SecureRandom.uuid}", currency_code: "USD", amount_minor: 100,
                                                  state:, safe_snapshot: {}, recorded_at: now, created_at: now, updated_at: now
                                                }])
    RecordingStudioBilling::Payment.find(id)
  end

  def complete_projection_command!(command, **result)
    command.update!(state: "succeeded", provider_reference: "provider-#{SecureRandom.uuid}",
                    normalized_result: result.merge("provider_account_recording_id" => command.provider_account_recording_id,
                                                    "provider_reference" => "projection-#{SecureRandom.uuid}"))
  end

  def insert_invoice(root:, account:, command:)
    now = Time.current
    id = SecureRandom.uuid
    RecordingStudioBilling::Invoice.insert_all!([{
                                                  id:, root_recording_id: root.id, account_recording_id: account.recording.id, financial_command_id: command.id,
                                                  provider_reference: "invoice-#{SecureRandom.uuid}", currency_code: "USD", total_minor: 100,
                                                  state: "issued", safe_snapshot: {}, issued_at: now, created_at: now, updated_at: now
                                                }])
    RecordingStudioBilling::Invoice.find(id)
  end

  def provider_market(provider)
    RecordingStudio.record!(
      action: "created",
      recordable: RecordingStudioBilling::Market.new(
        provider_account_recording: provider, key: "market_#{SecureRandom.hex(4)}", country_codes: ["US"],
        country_groups: {}, regional_country_codes: [], global_fallback: false, allowed_currency_codes: ["USD"],
        default_currency_code: "USD", priority: 1, specificity: 1, ppa_policy: "standard", rounding_policy: "half_up",
        tax_presentation_policy: "exclusive", verification_policy: "none"
      ), root_recording: provider.root_recording, parent_recording: provider.parent_recording
    ).recording
  end

  def trusted_inbound_event(command)
    endpoint = RecordingStudioWebhooks::EndpointLifecycle.create!(
      endpoint: RecordingStudioWebhooks::Endpoint.new(
        recording_studio_recording_id: command.root_recording_id, label: "Lifecycle receipt #{SecureRandom.hex(4)}",
        provider_name: "test", identity: {
          "billing_provider_adapter_key" => "test",
          "billing_provider_account_recording_id" => command.provider_account_recording_id,
          "billing_environment" => "test"
        }, metadata: {}, policy_overrides: {}
      ), actor: nil
    )
    issuance = endpoint.issue_token!
    RecordingStudioWebhooks::InboundEvent.create!(
      endpoint:, endpoint_token: issuance.endpoint_token, provider_name: endpoint.provider_name,
      event_type: "payment.completed", provider_event_id: "event-1", payload_digest: "a" * 64,
      deduplication_key: SecureRandom.uuid, payload: { "id" => "event-1" }, provenance: {}, endpoint_snapshot: endpoint.snapshot,
      token_snapshot: issuance.endpoint_token.snapshot, policy_snapshot: {}, received_at: Time.current, status: "accepted"
    )
  end
end
