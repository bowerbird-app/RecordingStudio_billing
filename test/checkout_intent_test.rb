# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class CheckoutIntentTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    clear_data!
    @actor = User.create!(email: "checkout-#{SecureRandom.hex(4)}@example.com", password: "Password1!", password_confirmation: "Password1!")
    RecordingStudioBilling.configuration.feature_definitions = {}
    RecordingStudioBilling.configuration.tax_policy = {}
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
    RecordingStudioBilling.configuration.reset_registries!
  end

  teardown { clear_data! }

  test "freezes country-specific EUR terms, reuses identical input, and defers provider work" do
    graph = published_catalogue
    italy = create_intent(graph, country: "IT", key: "same-key")
    existing = create_intent(graph, country: "IT", key: "same-key")
    germany = create_intent(graph, country: "DE", key: "germany-key")

    assert italy.created?
    assert existing.existing?
    assert germany.created?
    assert_equal italy.intent.id, existing.intent.id
    assert_equal "EUR", italy.intent.items.first.currency_code
    assert_equal graph[:italy_price].recording.id, italy.intent.items.first.price_recording_id
    assert_equal graph[:germany_price].recording.id, germany.intent.items.first.price_recording_id
    assert_equal 1_000, italy.intent.items.first.commercial_manifest.dig("canonical_data", "price", "amount_minor")
    assert_equal 1_200, germany.intent.items.first.commercial_manifest.dig("canonical_data", "price", "amount_minor")
    assert_equal "pending_provider", italy.intent.state
    assert_equal 0, graph[:adapter].calls
    assert_predicate italy.intent, :financial_command
    assert_equal "pending", italy.intent.financial_command.state
    assert_equal 1, italy.intent.attempts.count
    assert_equal "pending", italy.intent.attempts.first.state
    assert_equal italy.intent.financial_command_id, italy.intent.attempts.first.financial_command_id
    assert_includes italy.intent.financial_command.canonical_request.dig("authority", "commercial_manifest_digests"),
            italy.intent.items.first.manifest_digest
  end

  test "executes a pending checkout once outside a transaction and projects the command attempt" do
    graph = published_catalogue
    intent = create_intent(graph, country: "IT", key: "execute-success").intent
    adapter = graph[:adapter]

    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])

    attempt = intent.reload.attempts.first
    assert_equal 1, adapter.calls
    assert_equal [false], adapter.transaction_open_during_calls
    assert_equal "awaiting_confirmation", intent.state
    assert_equal "succeeded", attempt.state
    assert_predicate attempt, :completed_at?
    assert_equal intent.financial_command.attempts.first.id, attempt.financial_command_attempt_id
  end

  test "maps generic provider outcomes without completing uncertain or rejected checkout intents" do
    expectations = {
      duplicate: ["awaiting_confirmation", "succeeded"],
      invalid: ["failed", "failed"],
      provider_rejection: ["failed", "failed"],
      unsupported: ["requires_review", "failed"],
      provider_unavailable: ["requires_review", "failed"],
      pending: ["pending_provider", "unknown"],
      unknown_provider_state: ["pending_provider", "unknown"]
    }

    expectations.each do |outcome, (intent_state, attempt_state)|
      RecordingStudioBilling.configuration.reset_registries!
      graph = published_catalogue
      RecordingStudioBilling.configuration.reset_registries!
      RecordingStudioBilling.register_provider("fake", RecordingStudioBilling::FakeFinancialAdapter.new(outcome:, capabilities: graph[:adapter].capabilities))
      intent = create_intent(graph, country: "IT", key: "outcome-#{outcome}").intent

      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])

      assert_equal intent_state, intent.reload.state, outcome
      assert_equal attempt_state, intent.attempts.first.reload.state, outcome
      refute_equal "completed", intent.state, outcome
    end
  end

  test "timeout remains reconcilable and stores no raw provider data" do
    graph = published_catalogue
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :timeout_after_possible_success)
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.register_provider("fake", adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :timeout_after_possible_success, capabilities: graph[:adapter].capabilities))
    intent = create_intent(graph, country: "IT", key: "timeout").intent

    assert_raises(RecordingStudioBilling::FakeFinancialAdapter::TimeoutAfterPossibleSuccess) do
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    end

    attempt = intent.reload.attempts.first
    assert_equal "pending_provider", intent.state
    assert_equal "unknown", attempt.state
    refute_match(/secret|payload|url|payment/i, [attempt[:safe_result], attempt[:safe_error_details]].to_s)
  end

  test "recovery retains the provider mutation key and appends a correlated checkout attempt" do
    graph = published_catalogue
    pending = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :pending)
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.register_provider("fake", pending = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :pending, capabilities: graph[:adapter].capabilities))
    intent = create_intent(graph, country: "IT", key: "recover").intent
    command = intent.financial_command

    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    recovered = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :duplicate)
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.register_provider("fake", recovered = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :duplicate, capabilities: graph[:adapter].capabilities))
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root], recovery: true)

    attempts = intent.reload.attempts.order(:attempt_number).to_a
    assert_equal [1, 2], attempts.map(&:attempt_number)
    assert_equal command.attempts.order(:attempt_number).pluck(:id), attempts.map(&:financial_command_attempt_id)
    assert_equal [command.provider_idempotency_key], recovered.idempotency_keys
    assert_equal "awaiting_confirmation", intent.state
  end

  test "concurrent checkout workers produce one provider call" do
    graph = published_catalogue
    intent = create_intent(graph, country: "IT", key: "concurrent").intent
    ready = Queue.new
    release = Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent.id, root_recording: graph[:customer_root])
        rescue ArgumentError, ActiveRecord::Deadlocked
          nil
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    workers.each(&:join)

    assert_equal 1, graph[:adapter].calls
    assert_equal 1, intent.financial_command.reload.attempts.count
  end

  test "non-executable, cross-root, and browser-return-shaped requests never call a provider" do
    graph = published_catalogue
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    intent = create_intent(graph, country: "IT", key: "ineligible").intent

    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: other_root)
    end
    assert_raises(ArgumentError) do
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root], return_url: "https://invalid.test")
    end
    intent.financial_command.update!(state: "cancelled")
    intent.update!(state: "cancelled")
    assert_raises(ArgumentError) do
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    end
    assert_equal 0, graph[:adapter].calls
  end

  test "cancelled, expired, requote, and review intents cannot execute or recover" do
    %w[cancelled expired requires_requote requires_review].each do |state|
      RecordingStudioBilling.configuration.reset_registries!
      graph = published_catalogue
      intent = create_intent(graph, country: "IT", key: "blocked-#{state}").intent
      intent.financial_command.update!(state: "cancelled")
      intent.update!(state:)

      [false, true].each do |recovery|
        assert_raises(ArgumentError) do
          RecordingStudioBilling.execute_checkout_intent(
            checkout_intent: intent, root_recording: graph[:customer_root], recovery:
          )
        end
      end
      assert_equal 0, graph[:adapter].calls
    end
  end

  test "checkout attempt payloads reject provider data, credentials, URLs, and payment fields" do
    graph = published_catalogue
    intent = create_intent(graph, country: "IT", key: "unsafe-attempt").intent

    %w[raw_provider_payload provider_url api_key client_secret card_number payment_nonce].each do |unsafe_key|
      attempt = intent.attempts.first.dup
      attempt.safe_result = { unsafe_key => "https://invalid.test" }
      refute attempt.valid?, unsafe_key
      assert_includes attempt.errors[:safe_result], "must not contain credentials, signatures, or raw provider data"
    end
  end

  test "final market requote prevents checkout execution and generic executor stays Stripe-neutral" do
    graph = published_catalogue
    intent = create_intent(graph, country: "IT", key: "requote-execution").intent
    germany = RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("DE", :verified_account)
    RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(intent:, account_country: germany)

    assert_raises(ArgumentError) do
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    end
    assert_equal 0, graph[:adapter].calls
    source = File.read(Rails.root.join("../../app/services/recording_studio_billing/execute_checkout_intent.rb"))
    refute_match(/Stripe::|stripe_credential|:stripe/, source)
  end

  test "conflicting key, client financial fields, and final market changes require a fresh complete quote" do
    graph = published_catalogue
    created = create_intent(graph, country: "IT", key: "conflict-key")
    conflict = RecordingStudioBilling.create_checkout_intent(
      root_recording: graph[:customer_root], local_idempotency_key: "conflict-key", country_code: "DE",
      items: [{ billing_option_recording_id: graph[:option].recording.id, quantity: 1 }]
    )

    assert created.created?
    assert conflict.conflict?
    assert_raises(ArgumentError) do
      RecordingStudioBilling.create_checkout_intent(
        root_recording: graph[:customer_root], local_idempotency_key: "unsafe-key", country_code: "IT",
        items: [{ billing_option_recording_id: graph[:option].recording.id, quantity: 1, amount_minor: 1, provider_url: "https://invalid.test" }]
      )
    end

    verified_germany = RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("DE", :verified_account)
    updated = RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(intent: created.intent, account_country: verified_germany)

    assert_equal "requires_requote", updated.state
    assert_equal "cancelled", updated.financial_command.reload.state
    assert_equal "cancelled", updated.attempts.first.reload.state
    assert_equal graph[:italy_price].recording.id, updated.items.first.price_recording_id
    assert_equal "IT", updated.items.first.market_recording.recordable.country_codes.first
    assert_equal 1_000, updated.items.first.commercial_manifest.dig("canonical_data", "price", "amount_minor")
    refute_equal updated.items.first.manifest_digest, RecordingStudioBilling::CommercialManifestResolver.new(
      product: updated.items.first.product_recording.recordable,
      billing_option: updated.items.first.billing_option_recording.recordable,
      price: graph[:germany_price], market: graph[:germany_price].market_recording.recordable,
      currency_code: "EUR", quantity: 1, account_recording: updated.account_recording,
      trusted_context: { country_code: "DE", market_recording_id: graph[:germany_price].market_recording_id,
                         currency_code: "EUR", quantity: 1 }
    ).resolve!.fetch(:manifest_digest)

    RecordingStudioBilling::FinancialCommandExecutor.execute(command: updated.financial_command, provider_key: "fake")
    assert_equal 0, graph[:adapter].calls
  end

  test "rejects multi-item checkout before persisting an unschedulable intent" do
    graph = published_catalogue

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling.create_checkout_intent(
        root_recording: graph[:customer_root], local_idempotency_key: "multiple-items", country_code: "IT",
        items: [
          { billing_option_recording_id: graph[:option].recording.id, quantity: 1 },
          { billing_option_recording_id: graph[:option].recording.id, quantity: 1 }
        ]
      )
    end

    assert_equal "unsupported_checkout_composition", error.message
    assert_nil RecordingStudioBilling::CheckoutIntent.find_by(local_idempotency_key: "multiple-items")
  end

  test "final verification confirms unchanged complete terms and rejects unverified evidence" do
    graph = published_catalogue
    created = create_intent(graph, country: "IT", key: "final-confirmed")
    verified_italy = RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("IT", :verified_account)

    confirmed = RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(intent: created.intent, account_country: verified_italy)

    assert_equal "pending_provider", confirmed.state
    assert_equal created.intent.financial_command_id, confirmed.financial_command_id
    assert_equal 1, confirmed.attempts.count
    unverified = RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(intent: confirmed, account_country: "IT")
    assert_equal "requires_review", unverified.state
  end

  test "final verification sends unsupported provider composition to review without changing the quote" do
    graph = published_catalogue
    created = create_intent(graph, country: "IT", key: "final-unsupported")
    original_digest = created.intent.items.first.manifest_digest
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.register_provider("fake", RecordingStudioBilling::FakeFinancialAdapter.new(
      outcome: :success, capabilities: RecordingStudioBilling::ProviderCapabilities.new
    ))
    verified_italy = RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("IT", :verified_account)

    reviewed = RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(intent: created.intent, account_country: verified_italy)

    assert_equal "requires_review", reviewed.state
    assert_equal original_digest, reviewed.items.first.manifest_digest
    assert_equal "cancelled", reviewed.financial_command.reload.state
    assert_equal "cancelled", reviewed.attempts.first.reload.state
  end

  test "rejects browser return and client-controlled checkout fields" do
    graph = published_catalogue

    %w[amount_minor currency provider_url return_url success_url cancel_url].each do |unsafe_key|
      error = assert_raises(ArgumentError) do
        RecordingStudioBilling.create_checkout_intent(
          root_recording: graph[:customer_root], local_idempotency_key: "unsafe-#{unsafe_key}", country_code: "IT",
          items: [{ billing_option_recording_id: graph[:option].recording.id, quantity: 1, unsafe_key => "unsafe" }]
        )
      end
      assert_equal "unsupported checkout input", error.message
    end
  end

  test "fails closed for ambiguous markets and keeps generic checkout code Stripe-neutral" do
    graph = published_catalogue
    italy_market = graph[:italy_price].market_recording.recordable

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::MarketResolver.new(markets: [italy_market, italy_market]).resolve(
        stage: :provisional_charge, declaration_country: "IT"
      )
    end

    assert_match(/ambiguous market/, error.message)
    source = File.read(Rails.root.join("../../app/services/recording_studio_billing/create_checkout_intent.rb"))
    refute_match(/Stripe::|stripe_credential_resolver|stripe.*(?:return|url)/i, source)
  end

  test "database authority and history protections reject cross-root and mutable checkout records" do
    graph = published_catalogue
    created = create_intent(graph, country: "IT", key: "database-protection")
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    other_account = RecordingStudioBilling.ensure_account(root_recording: other_root, name: "Other account")

    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::CheckoutIntent.insert_all!([{
        id: SecureRandom.uuid, root_recording_id: graph[:customer_root].id, account_recording_id: other_account.recording.id,
        local_idempotency_key: "cross-root", request_fingerprint: "a" * 64, state: "draft", created_at: Time.current, updated_at: Time.current
      }])
    end
    assert_raises(ActiveRecord::StatementInvalid) { created.intent.items.first.update_column(:currency_code, "USD") }
    assert_raises(ActiveRecord::StatementInvalid) { created.intent.attempts.first.update_column(:state, "failed") }
    %w[requires_requote requires_review cancelled expired].each do |state|
      intent = state == "requires_review" ? created.intent : create_intent(graph, country: "IT", key: "state-#{state}").intent
      assert_equal "pending_provider", intent.state
      assert_equal "pending", intent.financial_command.state
      assert_equal "pending", intent.attempts.first.state
      assert_raises(ActiveRecord::StatementInvalid) { intent.update_column(:state, state) }
    end
    unbound_command = RecordingStudioBilling.create_financial_command(
      root_recording: graph[:customer_root], account_recording: created.intent.account_recording,
      command_type: "checkout", local_idempotency_key: "unbound-command", provider_account_recording: created.intent.items.first.provider_account_recording,
      provider_adapter_key: "fake", request: { checkout_intent_id: created.intent.id }
    ).command
    assert_raises(ActiveRecord::StatementInvalid) { created.intent.update_column(:financial_command_id, unbound_command.id) }
  end

  test "command creation failure leaves the quoted intent validated without a pending provider state" do
    graph = published_catalogue
    original_call = RecordingStudioBilling::CreateFinancialCommand.method(:call)
    RecordingStudioBilling::CreateFinancialCommand.define_singleton_method(:call) do |**|
      raise ArgumentError, "forced command failure"
    end

    begin
      assert_raises(ArgumentError) { create_intent(graph, country: "IT", key: "command-failure") }
    ensure
      RecordingStudioBilling::CreateFinancialCommand.define_singleton_method(:call, original_call)
    end

    intent = RecordingStudioBilling::CheckoutIntent.find_by!(local_idempotency_key: "command-failure")
    assert_equal "validated", intent.state
    assert_nil intent.financial_command_id
    refute RecordingStudioBilling::CheckoutIntent.where(state: "pending_provider", financial_command_id: nil).exists?
  end

  test "projects every supported commercial lifecycle mode from frozen completed checkout terms" do
    cases = {
      ["plan", "recurring", "month", 0, 0] => "free_plan",
      ["plan", "recurring", "month", 0, 1_000] => "monthly_subscription",
      ["plan", "recurring", "year", 0, 1_000] => "annual_subscription",
      ["plan", "recurring", "month", 14, 1_000] => "trial_subscription",
      ["addon", "recurring", "month", 0, 1_000] => "recurring_addon",
      ["addon", "one_time", nil, 0, 1_000] => "one_off_addon",
      ["credit_pack", "one_time", nil, 0, 1_000] => "one_off_credit_pack"
    }

    cases.each_with_index do |((kind, recurrence, interval, trial_days, amount), expected_mode), index|
      RecordingStudioBilling.configuration.reset_registries!
      graph = published_catalogue(kind:, recurrence:, interval:, trial_days:, amount:)
      intent = create_intent(graph, country: "IT", key: "lifecycle-#{index}").intent
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])

      result = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])

      assert result.projected?
      assert_equal "completed", intent.reload.state
      if expected_mode.start_with?("one_off")
        assert_equal expected_mode, result.purchase.mode
        assert_equal(expected_mode == "one_off_credit_pack" ? "credit_pack" : "one_off_addon", result.purchase.effects.sole.effect_kind)
      else
        assert_equal expected_mode, result.subscription.item_versions.sole.mode
        assert_equal(expected_mode == "trial_subscription" ? "trialing" : "active", result.subscription.state)
      end
    end
  end

  test "lifecycle projection is root isolated, idempotent, append-only, and provider neutral" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    intent = create_intent(graph, country: "IT", key: "project-idempotently").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    first = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    repeated = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))

    assert first.projected?
    assert repeated.existing?
    assert_equal 1, RecordingStudioBilling::SubscriptionItemVersion.where(subscription: first.subscription).count
    assert_raises(ActiveRecord::StatementInvalid) { first.subscription.item_versions.sole.update_column(:amount_minor, 1) }
    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: other_root)
    end
    source = File.read(Rails.root.join("../../app/services/recording_studio_billing/project_completed_checkout_intent.rb"))
    refute_match(/Stripe::|stripe_credential|:stripe/, source)
  end

  test "base plan variants replace one product line while recurring add-ons remain active" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    annual, = published_option(graph, product_recording: graph[:option].product_recording, kind: "plan", recurrence: "recurring", interval: "year")
    addon, = published_option(graph, kind: "addon", recurrence: "recurring", interval: "month",
                      price_feature_values: { "projects" => 8, "seats" => 2 })
    plan_intent = create_intent(graph, country: "IT", key: "base-monthly").intent
    addon_intent = create_intent(graph, country: "IT", key: "recurring-addon", option: addon).intent

    [plan_intent, addon_intent].each do |intent|
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
      RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    end
    replacement_intent = create_intent(graph, country: "IT", key: "base-annual", option: annual).intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: replacement_intent, root_recording: graph[:customer_root])
    subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: replacement_intent, root_recording: graph[:customer_root]).subscription

    plan_versions = subscription.item_versions.where(product_recording_id: graph[:option].product_recording_id).order(:version_number)
    addon_versions = subscription.item_versions.where(billing_option_recording_id: addon.recording.id).order(:version_number)
    assert_equal [1, 2], plan_versions.pluck(:version_number)
    assert_equal [graph[:option].recording.id, annual.recording.id], plan_versions.pluck(:billing_option_recording_id)
    assert_equal [graph[:option].product_recording_id], plan_versions.pluck(:line_key).uniq
    assert_predicate plan_versions.first, :effective_ends_at?
    assert_nil plan_versions.last.effective_ends_at
    assert_equal [1], addon_versions.pluck(:version_number)
    assert_nil addon_versions.sole.effective_ends_at
    assert_equal 2, subscription.item_versions.where(effective_ends_at: nil).count
    assert_equal 2, subscription.item_versions.where(effective_ends_at: nil).distinct.count(:line_key)
  end

  test "subscription lifecycle transitions are explicit and reject terminal or invalid moves" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month", trial_days: 7)
    intent = create_intent(graph, country: "IT", key: "lifecycle-transitions").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root]).subscription

    assert_equal "active", RecordingStudioBilling::SubscriptionLifecycle.activate(subscription:, root_recording: graph[:customer_root]).state
    assert_equal "paused", RecordingStudioBilling::SubscriptionLifecycle.pause(subscription:, root_recording: graph[:customer_root]).state
    assert_equal "active", RecordingStudioBilling::SubscriptionLifecycle.resume(subscription:, root_recording: graph[:customer_root]).state
    assert_equal "cancelled", RecordingStudioBilling::SubscriptionLifecycle.cancel(subscription:, root_recording: graph[:customer_root]).state
    assert_raises(ArgumentError) { RecordingStudioBilling::SubscriptionLifecycle.resume(subscription:, root_recording: graph[:customer_root]) }
  end

  test "lifecycle snapshots reject unsafe payloads and tampered manifests" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    intent = create_intent(graph, country: "IT", key: "lifecycle-safe").intent
    item = intent.items.sole
    item.commercial_manifest = { "raw_provider_payload" => "unsafe" }
    refute item.valid?

    manifest = RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: intent.items.sole.manifest_digest)
    assert_raises(ActiveRecord::StatementInvalid) { manifest.update_column(:canonical_data, {}) }
  end

  test "projects frozen lifecycle sources into idempotent root-scoped entitlements" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    intent = create_intent(graph, country: "IT", key: "entitlement-projection").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root]).subscription

    first = RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])

    assert_equal 4, first.grants.count
    assert_equal 4, RecordingStudioBilling::EntitlementGrant.where(root_recording: graph[:customer_root]).count
    assert RecordingStudioBilling.entitled?(root_recording: graph[:customer_root], feature_key: "enabled")
    assert_equal 3, RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "projects")
    assert_equal "pro", RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "edition")
    assert_equal({ "edition" => "pro", "enabled" => true, "projects" => 3, "seats" => 5 },
                 RecordingStudioBilling.effective_entitlements(root_recording: graph[:customer_root]))

    RecordingStudioBilling::SubscriptionLifecycle.pause(subscription:, root_recording: graph[:customer_root])
    assert_equal({}, RecordingStudioBilling.effective_entitlements(root_recording: graph[:customer_root]))
    assert_raises(ActiveRecord::StatementInvalid) { first.grants.first.update_column(:value, false) }
    source = File.read(Rails.root.join("../../app/services/recording_studio_billing/project_entitlements.rb"))
    refute_match(/Stripe::|stripe_credential|:stripe/, source)
  end

  test "numeric entitlement grants honor frozen maximum and minimum rules" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features.merge(
      "projects" => entitlement_features.fetch("projects").merge(merge_rule: "maximum", default: 3),
      "seats" => entitlement_features.fetch("seats").merge(merge_rule: "minimum", default: 5)
    )
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    project_subscription!(graph, key: "numeric-base")
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features.merge(
      "projects" => entitlement_features.fetch("projects").merge(merge_rule: "maximum", default: 10),
      "seats" => entitlement_features.fetch("seats").merge(merge_rule: "minimum", default: 2)
    )
    RecordingStudioBilling.configuration.reset_registries!
    addon_graph = published_catalogue(kind: "addon", recurrence: "recurring", interval: "month")
    addon_graph[:customer_root] = graph[:customer_root]
    project_subscription!(addon_graph, key: "numeric-addon")
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])

    assert_equal 10, RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "projects")
    assert_equal 2, RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "seats")
  end

  test "replace numeric entitlements reject conflicting active projected values" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    project_subscription!(graph, key: "replace-base")
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features.merge(
      "projects" => entitlement_features.fetch("projects").merge(default: 10)
    )
    RecordingStudioBilling.configuration.reset_registries!
    addon_graph = published_catalogue(kind: "addon", recurrence: "recurring", interval: "month")
    addon_graph[:customer_root] = graph[:customer_root]
    project_subscription!(addon_graph, key: "replace-addon")
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "projects")
    end
    assert_match(/replace values conflict/, error.message)
  end

  test "credit-pack projection is idempotent and the ledger rejects forged facts" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "credit_pack", recurrence: "one_time", interval: nil)
    intent = create_intent(graph, country: "IT", key: "credit-pack").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root]).purchase

    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    entry = RecordingStudioBilling::CreditLedgerEntry.sole

    assert_equal 5, RecordingStudioBilling.credit_balance(root_recording: graph[:customer_root], product_recording: purchase.product_recording_id)
    assert_equal 1, RecordingStudioBilling::CreditLedgerEntry.count
    assert_raises(ActiveRecord::StatementInvalid) { entry.update_column(:amount, 999) }
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::CreditLedgerEntry.insert_all!([entry.attributes.except("id", "created_at", "updated_at").merge(
        "id" => SecureRandom.uuid, "credit_key" => "forged", "amount" => 1, "created_at" => Time.current, "updated_at" => Time.current
      )])
    end
  end

  test "records root-scoped usage idempotently and protects its append-only history" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    project_subscription!(graph, key: "usage-entitlement")
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])

    created = RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 2,
                                                   idempotency_key: "usage-event", metadata: { "source" => "studio" })
    existing = RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 2,
                                                    idempotency_key: "usage-event")

    assert created.created?
    assert existing.existing?
    assert_equal created.event.id, existing.event.id
    assert_equal 2, RecordingStudioBilling.usage_total(root_recording: graph[:customer_root], usage_key: "seats")
    exhausted = RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 4,
                             idempotency_key: "exhausted-usage")
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Unentitled #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: other_root, name: "Unentitled account")
    unentitled = RecordingStudioBilling.record_usage(root_recording: other_root, usage_key: "seats", quantity: 1,
                              idempotency_key: "no-entitlement")

    assert exhausted.denied?
    assert_equal :exhausted_allowance, exhausted.reason
    assert unentitled.denied?
    assert_equal :no_entitlement, unentitled.reason
    assert_equal 1, RecordingStudioBilling::UsageEvent.where(root_recording: graph[:customer_root]).count
    assert_equal 0, RecordingStudioBilling::UsageEvent.where(root_recording: other_root).count
    assert_raises(ActiveRecord::StatementInvalid) { created.event.update_column(:quantity, 3) }
    assert_raises(RecordingStudioBilling::SafeFinancialPayload::UnsafeValue) do
      RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 1,
                                          idempotency_key: "unsafe-usage", metadata: { "provider_url" => "https://invalid.test" })
    end
  end

  test "concurrent usage at the remaining allowance creates exactly one event" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    project_subscription!(graph, key: "concurrent-usage-entitlement")
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 2,
                                        idempotency_key: "usage-before-race")
    ready = Queue.new
    release = Queue.new
    results = Queue.new

    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          results << RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 3,
                                                         idempotency_key: "remaining-usage-#{index}")
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)

    assert_equal %i[created denied], 2.times.map { results.pop.status }.sort
    assert_equal 2, RecordingStudioBilling::UsageEvent.where(root_recording: graph[:customer_root], usage_key: "seats").count
    assert_equal 5, RecordingStudioBilling.usage_total(root_recording: graph[:customer_root], usage_key: "seats")
  end

  test "a delayed worker with an earlier captured timestamp cannot bypass the locked allowance total" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    project_subscription!(graph, key: "reversed-usage-entitlement")
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 2,
                                        idempotency_key: "usage-before-reversed-race")

    earlier_timestamp = Time.current
    later_timestamp = earlier_timestamp + 1.second
    first_finished = Queue.new
    results = Queue.new

    later_worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result = RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 3,
                                                     idempotency_key: "later-timestamp", occurred_at: later_timestamp)
        results << result
        first_finished << true
      end
    end
    earlier_worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        first_finished.pop
        results << RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 3,
                                                        idempotency_key: "earlier-timestamp", occurred_at: earlier_timestamp)
      end
    end
    [later_worker, earlier_worker].each(&:join)

    statuses = 2.times.map { results.pop }
    assert_equal %i[created denied], statuses.map(&:status).sort
    assert_equal :exhausted_allowance, statuses.find(&:denied?).reason
    assert_equal 5, RecordingStudioBilling.usage_total(root_recording: graph[:customer_root], usage_key: "seats")
  end

  test "consumes credits once with source authority and includes debits in the balance" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "credit_pack", recurrence: "one_time", interval: nil)
    intent = create_intent(graph, country: "IT", key: "consume-credits").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root]).purchase
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])

    created = RecordingStudioBilling.consume_credits(root_recording: graph[:customer_root], product_recording: purchase.product_recording_id,
                                                      amount: 3, usage_key: "seats", idempotency_key: "consume-once")
    existing = RecordingStudioBilling.consume_credits(root_recording: graph[:customer_root], product_recording: purchase.product_recording_id,
                                                       amount: 3, usage_key: "seats", idempotency_key: "consume-once")

    assert created.created?
    assert existing.existing?
    assert_equal created.entry.id, existing.entry.id
    assert_equal(-3, created.entry.amount)
    assert_equal 2, RecordingStudioBilling.credit_balance(root_recording: graph[:customer_root], product_recording: purchase.product_recording_id)
    assert_raises(ActiveRecord::StatementInvalid) { created.entry.update_column(:amount, -4) }
    usage = RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 1,
                                                idempotency_key: "forged-oversized-debit").event
    oversized_debit = created.entry.attributes.except("id", "created_at", "updated_at").merge(
      "id" => SecureRandom.uuid, "purchase_effect_id" => nil, "usage_event_id" => usage.id,
      "idempotency_key" => usage.idempotency_key, "amount" => -3, "effective_at" => Time.current,
      "created_at" => Time.current, "updated_at" => Time.current
    )
    assert_raises(ActiveRecord::StatementInvalid) { RecordingStudioBilling::CreditLedgerEntry.insert_all!([oversized_debit]) }
    forged = created.entry.attributes.except("id", "created_at", "updated_at").merge(
      "id" => SecureRandom.uuid, "product_recording_id" => SecureRandom.uuid, "created_at" => Time.current, "updated_at" => Time.current
    )
    assert_raises(ActiveRecord::StatementInvalid) { RecordingStudioBilling::CreditLedgerEntry.insert_all!([forged]) }
  end

  test "concurrent last-credit consumption permits exactly one debit" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "credit_pack", recurrence: "one_time", interval: nil)
    intent = create_intent(graph, country: "IT", key: "concurrent-credits").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root]).purchase
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    ready = Queue.new
    release = Queue.new
    results = Queue.new

    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          results << RecordingStudioBilling.consume_credits(root_recording: graph[:customer_root], product_recording: purchase.product_recording_id,
                                                             amount: 5, usage_key: "seats", idempotency_key: "last-credit-#{index}")
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)

    assert_equal %i[created denied], 2.times.map { results.pop.status }.sort
    assert_equal 1, RecordingStudioBilling::CreditLedgerEntry.where(direction: "debit").count
    assert_equal 0, RecordingStudioBilling.credit_balance(root_recording: graph[:customer_root], product_recording: purchase.product_recording_id)
  end

  test "public entitlement APIs normalize an account child recording and fail closed across roots" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    intent = create_intent(graph, country: "IT", key: "normalized-root").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    account_child = RecordingStudioBilling::Account.with_current_recording.find_by!(root_recording: graph[:customer_root]).recording
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: other_root, name: "Other account")

    assert RecordingStudioBilling.entitled?(root_recording: account_child, feature_key: "enabled")
    assert_equal 3, RecordingStudioBilling.feature_value(root_recording: account_child, feature_key: "projects")
    assert_equal "pro", RecordingStudioBilling.effective_entitlements(root_recording: account_child).fetch("edition")
    assert_equal 0, RecordingStudioBilling.credit_balance(root_recording: account_child, product_recording: SecureRandom.uuid)
    assert_equal({}, RecordingStudioBilling.effective_entitlements(root_recording: other_root))
    refute RecordingStudioBilling.entitled?(root_recording: other_root, feature_key: "enabled")
    assert_nil RecordingStudioBilling.feature_value(root_recording: other_root, feature_key: "projects")
  end

  test "entitlement and credit ledger triggers reject forged source facts" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "credit_pack", recurrence: "one_time", interval: nil)
    intent = create_intent(graph, country: "IT", key: "trigger-facts").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    grant = RecordingStudioBilling::EntitlementGrant.first
    entry = RecordingStudioBilling::CreditLedgerEntry.sole
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    other_account = RecordingStudioBilling.ensure_account(root_recording: other_root, name: "Other account").recording

    [{ "value" => false }, { "merge_rule" => "maximum" }, { "root_recording_id" => other_root.id, "account_recording_id" => other_account.id },
     { "source_type" => "RecordingStudioBilling::SubscriptionItemVersion" }].each do |changes|
      assert_raises(ActiveRecord::StatementInvalid) { insert_grant!(grant, changes) }
    end
    assert_raises(ActiveRecord::StatementInvalid) { grant.update_column(:feature_key, "forged") }
    assert_raises(ActiveRecord::StatementInvalid) { insert_ledger!(entry, "amount" => entry.amount + 1) }
    assert_raises(ActiveRecord::StatementInvalid) { insert_ledger!(entry, "product_recording_id" => SecureRandom.uuid) }
    assert_raises(ActiveRecord::StatementInvalid) { insert_ledger!(entry, "root_recording_id" => other_root.id, "account_recording_id" => other_account.id) }
    RecordingStudioBilling.configuration.reset_registries!
    addon_graph = published_catalogue(kind: "addon", recurrence: "one_time", interval: nil)
    addon_intent = create_intent(addon_graph, country: "IT", key: "non-credit-effect").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: addon_intent, root_recording: addon_graph[:customer_root])
    purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: addon_intent, root_recording: addon_graph[:customer_root]).purchase
    effect = purchase.effects.sole
    forged = entry.attributes.except("id", "created_at", "updated_at").merge("id" => SecureRandom.uuid,
      "purchase_effect_id" => effect.id, "root_recording_id" => effect.root_recording_id, "account_recording_id" => effect.account_recording_id,
      "product_recording_id" => purchase.product_recording_id, "manifest_digest" => effect.manifest_digest, "created_at" => Time.current, "updated_at" => Time.current)
    assert_raises(ActiveRecord::StatementInvalid) { RecordingStudioBilling::CreditLedgerEntry.insert_all!([forged]) }
  end

  test "one-off add-on grants remain effective while terminal subscriptions do not" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "addon", recurrence: "one_time", interval: nil)
    intent = create_intent(graph, country: "IT", key: "one-off-addon").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    assert RecordingStudioBilling.entitled?(root_recording: graph[:customer_root], feature_key: "enabled")

    { paused: :pause, cancelled: :cancel, expired: :expire }.each do |state, transition|
      RecordingStudioBilling.configuration.reset_registries!
      subscription_graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
      subscription_intent = create_intent(subscription_graph, country: "IT", key: "terminal-#{state}").intent
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: subscription_intent, root_recording: subscription_graph[:customer_root])
      subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: subscription_intent, root_recording: subscription_graph[:customer_root]).subscription
      RecordingStudioBilling::SubscriptionLifecycle.public_send(transition, subscription:, root_recording: subscription_graph[:customer_root])
      RecordingStudioBilling.project_entitlements(root_recording: subscription_graph[:customer_root])
      assert_equal({}, RecordingStudioBilling.effective_entitlements(root_recording: subscription_graph[:customer_root]))
    end
  end

  test "conflicting active projected variants raise ambiguity through the public API" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    project_subscription!(graph, key: "variant-base")
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features.merge(
      "edition" => entitlement_features.fetch("edition").merge(default: "enterprise")
    )
    RecordingStudioBilling.configuration.reset_registries!
    addon_graph = published_catalogue(kind: "addon", recurrence: "recurring", interval: "month")
    addon_graph[:customer_root] = graph[:customer_root]
    project_subscription!(addon_graph, key: "variant-addon")
    RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])

    assert_raises(RecordingStudioBilling::EntitlementAccess::AmbiguousVariant) do
      RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "edition")
    end
  end

  private

  def create_intent(graph, country:, key:, option: graph[:option])
    RecordingStudioBilling.create_checkout_intent(
      root_recording: graph[:customer_root], local_idempotency_key: key, country_code: country,
      items: [{ billing_option_recording_id: option.recording.id, quantity: 1 }]
    )
  end

  def project_subscription!(graph, key:)
    intent = create_intent(graph, country: "IT", key:).intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root]).subscription
  end

  def published_catalogue(kind: "service", recurrence: "one_time", interval: nil, trial_days: 0, amount: 1_000)
    provider_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: provider_root, key: "billing_#{SecureRandom.hex(4)}")
    provider_recording = record_child(
      RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}",
                                                  adapter_key: "fake", name: "Fake", environment: "test", configuration: {}, capabilities: [], supported_markets: %w[IT DE], supported_currencies: ["EUR"]),
      provider_root, admin.recording
    )
    italy_market = market("italy", "IT", provider_recording, provider_root, admin.recording, "requote")
    germany_market = market("germany", "DE", provider_recording, provider_root, admin.recording, "requote")
    graph = { provider_root:, admin:, provider_recording:, italy_market:, germany_market: }
    option, published_italy_price, published_germany_price = published_option(graph, kind:, recurrence:, interval:, trial_days:, amount:)
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success, capabilities: RecordingStudioBilling::ProviderCapabilities.new(operations: ["checkout"], currencies: ["EUR"], markets: %w[IT DE], collection_methods: ["automatic"], checkout_modes: ["redirect"], quantities: ["fixed"], composition: ["single"]))
    RecordingStudioBilling.register_provider("fake", adapter)
    customer_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Customer #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: customer_root, name: "Customer account")
    graph.merge(customer_root:, option:, italy_price: published_italy_price, germany_price: published_germany_price, adapter:)
  end

  def published_option(graph, product_recording: nil, kind:, recurrence:, interval:, trial_days: 0, amount: 1_000, option_feature_values: {}, price_feature_values: {})
    product_recording ||= record_child(RecordingStudioBilling::Product.new(provider_account_recording: graph[:provider_recording], key: "product_#{SecureRandom.hex(4)}", kind:, feature_values: {}), graph[:provider_root], graph[:admin].recording)
    option_recording = record_child(RecordingStudioBilling::BillingOption.new(product_recording: product_recording, key: "option_#{SecureRandom.hex(4)}", recurrence:, interval:, interval_count: interval && 1, quantity_mode: "fixed", default_quantity: 1, pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0, trial_days:, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive", feature_values: option_feature_values), graph[:provider_root], product_recording)
    RecordingStudioBilling.configuration.feature_definitions.each do |key, definition|
      record_child(RecordingStudioBilling::Feature.new(product_recording:, key:, kind: definition.fetch("type"), definition: {}), graph[:provider_root], product_recording)
    end
    italy_price = price("italy", option_recording, graph[:italy_market], amount, graph[:provider_root], price_feature_values)
    germany_price = price("germany", option_recording, graph[:germany_market], amount + 200, graph[:provider_root], price_feature_values)
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:provider_root], price_recording_ids: [italy_price.id, germany_price.id], actor: @actor)
    [
      RecordingStudioBilling::BillingOption.with_current_recording.find_by!(key: option_recording.recordable.key),
      RecordingStudioBilling::Price.with_current_recording.find_by!(key: italy_price.recordable.key),
      RecordingStudioBilling::Price.with_current_recording.find_by!(key: germany_price.recordable.key)
    ]
  end

  def market(key, country, provider, root, parent, verification_policy)
    record_child(RecordingStudioBilling::Market.new(provider_account_recording: provider, key: "#{key}_market", country_codes: [country], country_groups: {}, allowed_currency_codes: ["EUR"], default_currency_code: "EUR", priority: 10, specificity: 1, fallback: false, ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive", verification_policy:), root, parent)
  end

  def price(key, option, market, amount, root, feature_values = {})
    record_child(RecordingStudioBilling::Price.new(billing_option_recording: option, market_recording: market, key: "#{key}_price", amount_minor: amount, currency_code: "EUR", currency_exponent: 2, pricing_model: "flat", version: 1, scope: "default", feature_values:), root, option)
  end

  def record_child(recordable, root, parent)
    RecordingStudio::Recording.unscoped.find(RecordingStudio.record!(action: "created", recordable:, root_recording: root, parent_recording: parent).recording.id)
  end

  def clear_data!
    connection = ActiveRecord::Base.connection
    tables = [RecordingStudioBilling::UsageEvent, RecordingStudioBilling::EntitlementGrant, RecordingStudioBilling::CreditLedgerEntry, RecordingStudioBilling::PurchaseEffect, RecordingStudioBilling::Purchase, RecordingStudioBilling::SubscriptionItemVersion, RecordingStudioBilling::Subscription, RecordingStudioBilling::CheckoutAttempt, RecordingStudioBilling::CheckoutIntentItem, RecordingStudioBilling::CheckoutIntent, RecordingStudioBilling::FinancialCommand, RecordingStudioBilling::CommercialPublicationCandidate, RecordingStudioBilling::CommercialManifest, *RecordingStudioBilling::RECORDABLE_TYPES.map(&:constantize)].map(&:table_name)
    connection.execute("TRUNCATE TABLE #{tables.map { |table| connection.quote_table_name(table) }.join(', ')} RESTART IDENTITY CASCADE")
    RecordingStudio::Event.unscoped.delete_all
    RecordingStudio::Recording.unscoped.delete_all
    Workspace.delete_all
    AdminRoot.delete_all
    User.delete_all
  end

  def insert_grant!(grant, changes)
    attributes = grant.attributes.except("id", "created_at", "updated_at").merge(
      "id" => SecureRandom.uuid, "created_at" => Time.current, "updated_at" => Time.current
    ).merge(changes)
    RecordingStudioBilling::EntitlementGrant.insert_all!([attributes])
  end

  def insert_ledger!(entry, changes)
    attributes = entry.attributes.except("id", "created_at", "updated_at").merge(
      "id" => SecureRandom.uuid, "created_at" => Time.current, "updated_at" => Time.current
    ).merge(changes)
    RecordingStudioBilling::CreditLedgerEntry.insert_all!([attributes])
  end

  def entitlement_features
    {
      "enabled" => { source: "catalogue", merge_rule: "replace", default: true, type: "boolean", meter_key: nil, usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 1, validation: {} },
      "projects" => { source: "catalogue", merge_rule: "replace", default: 3, type: "limit", meter_key: nil, usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 2, validation: { "minimum" => 0 } },
      "seats" => { source: "catalogue", merge_rule: "replace", default: 5, type: "allowance", meter_key: nil, usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 3, validation: { "minimum" => 0 } },
      "edition" => { source: "catalogue", merge_rule: "replace", default: "pro", type: "variant", meter_key: nil, usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 4, validation: {} }
    }
  end
end