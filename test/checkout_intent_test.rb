# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class CheckoutIntentTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    acquire_database_lock!
    clear_data!
    @actor = User.create!(email: "checkout-#{SecureRandom.hex(4)}@example.com", password: "Password1!",
                          password_confirmation: "Password1!")
    RecordingStudioBilling.configuration.feature_definitions = {}
    RecordingStudioBilling.configuration.tax_policy = {}
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
    RecordingStudioBilling.configuration.billing_location_context_resolver = lambda do |**|
      { host_country: verified_country("IT", :host) }
    end
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

  test "execution requotes conflicting verified provider terms before claiming a provider command" do
    graph = published_catalogue
    intent = create_intent(graph, country: "IT", key: "execution-requote").intent
    frozen_item = intent.items.first

    result = RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent,
                                                            root_recording: graph[:customer_root],
                                                            provider_country: verified_country("DE", :provider))

    assert_equal "requires_requote", result.state
    assert_equal "cancelled", intent.financial_command.reload.state
    assert_equal "cancelled", intent.attempts.first.reload.state
    assert_equal 0, graph[:adapter].calls
    assert_equal graph[:italy_price].recording.id, frozen_item.reload.price_recording_id
    assert_equal "EUR", frozen_item.currency_code
  end

  test "execution without trusted final location evidence fails closed into review" do
    RecordingStudioBilling.configuration.billing_location_context_resolver = nil
    graph = published_catalogue
    intent = create_intent(graph, country: "IT", key: "execution-review").intent

    result = RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent,
                                                            root_recording: graph[:customer_root])

    assert_equal "requires_review", result.state
    assert_equal "cancelled", intent.financial_command.reload.state
    assert_equal "cancelled", intent.attempts.first.reload.state
    assert_equal 0, graph[:adapter].calls
  end

  test "account settings country preference cannot authorize or reprice checkout execution" do
    graph = published_catalogue
    intent = create_intent(graph, country: "IT", key: "settings-country").intent
    frozen_item = intent.items.first
    RecordingStudioBilling::UpdateAccountPreferences.call(
      root_recording: graph[:customer_root], account_recording: graph[:account_recording],
      attributes: { billing_country_code: "DE" }, actor: @actor
    )
    RecordingStudioBilling.configuration.billing_location_context_resolver = nil

    result = RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent,
                                                            root_recording: graph[:customer_root])

    assert_equal "requires_review", result.state
    assert_equal "cancelled", intent.financial_command.reload.state
    assert_equal 0, graph[:adapter].calls
    assert_equal graph[:italy_price].recording.id, frozen_item.reload.price_recording_id
    assert_equal 1_000, frozen_item.commercial_manifest.dig("canonical_data", "price", "amount_minor")
  end

  test "trusted provider and host evidence authorize matching final checkout terms" do
    graph = published_catalogue
    provider_intent = create_intent(graph, country: "IT", key: "provider-final-terms").intent

    RecordingStudioBilling.execute_checkout_intent(
      checkout_intent: provider_intent, root_recording: graph[:customer_root],
      provider_country: verified_country("IT", :provider)
    )

    host_intent = create_intent(graph, country: "IT", key: "host-final-terms").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: host_intent, root_recording: graph[:customer_root])

    assert_equal 2, graph[:adapter].calls
    assert_equal "awaiting_confirmation", provider_intent.reload.state
    assert_equal "awaiting_confirmation", host_intent.reload.state
  end

  test "ambiguous final market evidence requires review without provider execution" do
    graph = published_catalogue
    intent = create_intent(graph, country: "IT", key: "ambiguous-final-market").intent
    ambiguous_market = market("italy_duplicate", "IT", graph[:provider_recording], graph[:provider_root], graph[:admin].recording,
                              "requote")
    ambiguous_price = price("italy_duplicate", graph[:option].recording, ambiguous_market,
                            1_000, graph[:provider_root])
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:provider_root],
                                                         price_recording_ids: [ambiguous_price.id], actor: @actor)

    result = RecordingStudioBilling.execute_checkout_intent(
      checkout_intent: intent, root_recording: graph[:customer_root],
      provider_country: verified_country("IT", :provider)
    )

    assert_equal "requires_review", result.state
    assert_equal "cancelled", intent.financial_command.reload.state
    assert_equal "cancelled", intent.attempts.first.reload.state
    assert_equal 0, graph[:adapter].calls
  end

  test "maps generic provider outcomes without completing uncertain or rejected checkout intents" do
    expectations = {
      duplicate: %w[awaiting_confirmation succeeded],
      invalid: %w[failed failed],
      provider_rejection: %w[failed failed],
      unsupported: %w[requires_review failed],
      provider_unavailable: %w[requires_review failed],
      pending: %w[pending_provider unknown],
      unknown_provider_state: %w[pending_provider unknown]
    }

    expectations.each do |outcome, (intent_state, attempt_state)|
      RecordingStudioBilling.configuration.reset_registries!
      graph = published_catalogue
      RecordingStudioBilling.configuration.reset_registries!
      RecordingStudioBilling.register_provider("fake",
                                               RecordingStudioBilling::FakeFinancialAdapter.new(outcome:,
                                                                                                capabilities: graph[:adapter].capabilities))
      intent = create_intent(graph, country: "IT", key: "outcome-#{outcome}").intent

      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])

      assert_equal intent_state, intent.reload.state, outcome
      assert_equal attempt_state, intent.attempts.first.reload.state, outcome
      refute_equal "completed", intent.state, outcome
    end
  end

  test "timeout remains reconcilable and stores no raw provider data" do
    graph = published_catalogue
    RecordingStudioBilling.configuration.reset_registries!
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :timeout_after_possible_success,
                                                               capabilities: graph[:adapter].capabilities)
    RecordingStudioBilling.register_provider("fake", adapter)
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
    RecordingStudioBilling.configuration.reset_registries!
    pending = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :pending,
                                                               capabilities: graph[:adapter].capabilities)
    RecordingStudioBilling.register_provider("fake", pending)
    intent = create_intent(graph, country: "IT", key: "recover").intent
    command = intent.financial_command

    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.configuration.reset_registries!
    recovered = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :duplicate,
                                                                 capabilities: graph[:adapter].capabilities)
    RecordingStudioBilling.register_provider("fake", recovered)
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root],
                                                   recovery: true)

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
          RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent.id,
                                                         root_recording: graph[:customer_root])
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
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root],
                                                     return_url: "https://invalid.test")
    end
    intent.financial_command.update!(state: "cancelled")
    intent.update!(state: "cancelled")
    assert_raises(ArgumentError) do
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    end
    assert_equal 0, graph[:adapter].calls
  end

  test "cancelled, expired, requote, restart, review, and rejected intents cannot execute or recover" do
    %w[cancelled expired requires_requote requires_restart requires_review rejected].each do |state|
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
    RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(
      intent:, account_country: germany
    )

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
    updated = RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(
      intent: created.intent, account_country: verified_germany
    )

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

  test "final Charge Market changes requote restart reject or review without keeping a cheaper ineligible price" do
    {
      "requote" => "requires_requote",
      "restart" => "requires_restart",
      "reject" => "rejected",
      "review" => "requires_review"
    }.each do |policy, state|
      RecordingStudioBilling.configuration.reset_registries!
      graph = published_catalogue(germany_verification_policy: policy)
      intent = create_intent(graph, country: "IT", key: "final-policy-#{policy}").intent
      frozen_item = intent.items.first

      result = RecordingStudioBilling::CreateCheckoutIntent.new(
        root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []
      ).verify_final_market!(intent:, account_country: verified_country("DE", :verified_account))

      assert_equal state, result.state, policy
      assert_equal "cancelled", result.financial_command.reload.state
      assert_equal "cancelled", result.attempts.first.reload.state
      assert_equal graph[:italy_price].recording.id, frozen_item.reload.price_recording_id
      assert_equal 1_000, frozen_item.commercial_manifest.dig("canonical_data", "price", "amount_minor")
      assert_equal 1_200, graph[:germany_price].amount_minor
    end
  end

  test "client presentation preference is frozen and cannot set money or Charge Market" do
    graph = published_catalogue(checkout_modes: %w[embedded redirect payment_link invoice no_charge])

    %w[embedded redirect payment_link invoice].each do |presentation|
      intent = create_intent(graph, country: "IT", key: "presentation-#{presentation}", presentation:).intent

      assert_equal presentation, intent.presentation_preference
      assert_equal presentation, intent.items.sole.presentation
      assert_equal 1_000, intent.items.sole.commercial_manifest.dig("canonical_data", "price", "amount_minor")
    end

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling.create_checkout_intent(
        root_recording: graph[:customer_root], local_idempotency_key: "forged-market", country_code: "IT",
        presentation: "redirect",
        items: [{ billing_option_recording_id: graph[:option].recording.id, quantity: 1,
                  market: "DE", amount_minor: 1, tax: "forged" }]
      )
    end
    assert_equal "unsupported checkout input", error.message
  end

  test "creates a compatible multi-item hybrid checkout and binds every frozen manifest" do
    graph = published_catalogue
    recurring, = published_option(graph, kind: "plan", recurrence: "recurring", interval: "month")
    addon, = published_option(graph, kind: "addon", recurrence: "one_time", interval: nil)
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.register_provider("fake", RecordingStudioBilling::FakeFinancialAdapter.new(
                                                       outcome: :success, capabilities: RecordingStudioBilling::ProviderCapabilities.new(
                                                         operations: ["checkout"], currencies: ["EUR"], markets: %w[IT DE], collection_methods: ["automatic"],
                                                         checkout_modes: ["redirect"], quantities: ["fixed"], composition: %w[single mixed]
                                                       )
                                                     ))

    result = RecordingStudioBilling.create_checkout_intent(
      root_recording: graph[:customer_root], local_idempotency_key: "multiple-items", country_code: "IT",
      items: [{ billing_option_recording_id: recurring.recording.id, quantity: 1 },
              { billing_option_recording_id: addon.recording.id, quantity: 1 }]
    )

    assert result.created?
    assert_equal 2, result.intent.items.count
    assert_equal result.intent.items.map(&:manifest_digest).sort,
                 result.intent.financial_command.canonical_request.dig("authority", "commercial_manifest_digests")
  end

  test "rejects a multi-item checkout with incompatible recurring intervals" do
    graph = published_catalogue
    monthly, = published_option(graph, kind: "plan", recurrence: "recurring", interval: "month")
    annual, = published_option(graph, kind: "plan", recurrence: "recurring", interval: "year")
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.register_provider("fake", RecordingStudioBilling::FakeFinancialAdapter.new(
                                                       outcome: :success, capabilities: RecordingStudioBilling::ProviderCapabilities.new(
                                                         operations: ["checkout"], currencies: ["EUR"], markets: %w[IT DE], collection_methods: ["automatic"],
                                                         checkout_modes: ["redirect"], quantities: ["fixed"], composition: %w[single mixed]
                                                       )
                                                     ))

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling.create_checkout_intent(
        root_recording: graph[:customer_root], local_idempotency_key: "mixed-intervals", country_code: "IT",
        items: [{ billing_option_recording_id: monthly.recording.id, quantity: 1 },
                { billing_option_recording_id: annual.recording.id, quantity: 1 }]
      )
    end

    assert_equal "mixed_recurring_intervals", error.message
    assert_nil RecordingStudioBilling::CheckoutIntent.find_by(local_idempotency_key: "mixed-intervals")
  end

  test "rejects disabled checkout options and duplicate option selections before persistence" do
    graph = published_catalogue(checkout_policy: "disabled")

    assert_raises(ActiveRecord::RecordNotFound) do
      create_intent(graph, country: "IT", key: "disabled-option")
    end
    assert_nil RecordingStudioBilling::CheckoutIntent.find_by(local_idempotency_key: "disabled-option")

    RecordingStudioBilling.configuration.reset_registries!
    graph = published_catalogue
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling.create_checkout_intent(
        root_recording: graph[:customer_root], local_idempotency_key: "duplicate-option", country_code: "IT",
        items: [{ billing_option_recording_id: graph[:option].recording.id, quantity: 1 },
                { billing_option_recording_id: graph[:option].recording.id, quantity: 1 }]
      )
    end
    assert_equal "duplicate checkout option", error.message
    assert_nil RecordingStudioBilling::CheckoutIntent.find_by(local_idempotency_key: "duplicate-option")
  end

  test "evaluates product requires and excludes rules against active subscription products" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    addon, = published_option(graph, kind: "addon", recurrence: "recurring", interval: "month")
    record_child(
      RecordingStudioBilling::ProductRule.new(product_recording: addon.product_recording,
                                              target_product_recording: graph[:option].product_recording,
                                              key: "requires_plan_#{SecureRandom.hex(4)}", rule_type: "requires", conditions: {}),
      graph[:provider_root], graph[:admin].recording
    )
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:provider_root],
                                                         price_recording_ids: [graph[:italy_price].recording.id], actor: @actor)
    project_subscription!(graph, key: "active-plan")

    assert create_intent(graph, country: "IT", key: "requires-active-plan", option: addon).created?
  end

  test "rejects a requested addon that excludes an active plan" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    addon, = published_option(graph, kind: "addon", recurrence: "recurring", interval: "month")
    excludes_plan = record_child(
      RecordingStudioBilling::ProductRule.new(product_recording: addon.product_recording,
                                              target_product_recording: graph[:option].product_recording,
                                              key: "excludes_plan_#{SecureRandom.hex(4)}", rule_type: "excludes", conditions: {}),
      graph[:provider_root], graph[:admin].recording
    )
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:provider_root],
                                                         price_recording_ids: [graph[:italy_price].recording.id], actor: @actor)
    project_subscription!(graph, key: "active-plan-excluded-by-addon")

    error = assert_raises(ArgumentError) do
      create_intent(graph, country: "IT", key: "excludes-active-plan", option: addon)
    end
    assert_includes error.message, excludes_plan.recordable.key
  end

  test "rejects a requested addon excluded by an active plan" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    project_subscription!(graph, key: "active-plan-excludes-addon")
    addon, = published_option(graph, kind: "addon", recurrence: "recurring", interval: "month")
    admin = current_recordable(graph[:admin].recording)
    excludes_addon = record_child(
      RecordingStudioBilling::ProductRule.new(product_recording: graph[:option].product_recording,
                                              target_product_recording: addon.product_recording,
                                              key: "plan_excludes_#{SecureRandom.hex(4)}", rule_type: "excludes", conditions: {}),
      graph[:provider_root], admin.recording
    )
    excludes_addon_key = excludes_addon.recordable.key
    italy_price = current_recordable(graph[:italy_price].recording)
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:provider_root],
                                                         price_recording_ids: [italy_price.recording.id], actor: @actor)

    error = assert_raises(ArgumentError) do
      create_intent(graph, country: "IT", key: "excluded-by-active-plan", option: addon)
    end
    assert_includes error.message, excludes_addon_key
  end

  test "enforces active product requires and available-with rules against the resulting selection" do
    %w[requires available_with].each do |rule_type|
      RecordingStudioBilling.configuration.reset_registries!
      graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
      requested_addon, = published_option(graph, kind: "addon", recurrence: "recurring", interval: "month")
      required_addon, = published_option(graph, kind: "addon", recurrence: "recurring", interval: "month")
      project_subscription!(graph, key: "active-plan-#{rule_type}")
      admin = current_recordable(graph[:admin].recording)
      rule = record_child(
        RecordingStudioBilling::ProductRule.new(product_recording: graph[:option].product_recording,
                                                target_product_recording: required_addon.product_recording,
                                                key: "plan_#{rule_type}_#{SecureRandom.hex(4)}", rule_type:, conditions: {}),
        graph[:provider_root], admin.recording
      )
      rule_key = rule.recordable.key
      italy_price = current_recordable(graph[:italy_price].recording)
      RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:provider_root],
                                                           price_recording_ids: [italy_price.recording.id], actor: @actor)

      error = assert_raises(ArgumentError) do
        create_intent(graph, country: "IT", key: "missing-#{rule_type}", option: requested_addon)
      end
      assert_includes error.message, rule_key
    end
  end

  test "final verification confirms unchanged complete terms and rejects unverified evidence" do
    graph = published_catalogue
    created = create_intent(graph, country: "IT", key: "final-confirmed")
    verified_italy = RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("IT", :verified_account)

    confirmed = RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(
      intent: created.intent, account_country: verified_italy
    )

    assert_equal "pending_provider", confirmed.state
    assert_equal created.intent.financial_command_id, confirmed.financial_command_id
    assert_equal 1, confirmed.attempts.count
    unverified = RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(
      intent: confirmed, account_country: "IT"
    )
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

    reviewed = RecordingStudioBilling::CreateCheckoutIntent.new(root_recording: graph[:customer_root], local_idempotency_key: "unused", items: []).verify_final_market!(
      intent: created.intent, account_country: verified_italy
    )

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
    %w[requires_requote requires_restart requires_review rejected cancelled expired].each do |state|
      intent = if state == "requires_review"
                 created.intent
               else
                 create_intent(graph, country: "IT",
                                      key: "state-#{state}").intent
               end
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

      result = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                        root_recording: graph[:customer_root])

      assert result.projected?
      assert_equal "completed", intent.reload.state
      if expected_mode.start_with?("one_off")
        assert_equal expected_mode, result.purchase.mode
        assert_equal result.purchase.recording.id, result.purchase.to_param
        assert_equal "RecordingStudioBilling::Account", result.purchase.recording.parent_recording.recordable_type
      else
        assert_equal expected_mode, result.subscription.lines.sole.mode
        assert_equal(expected_mode == "trial_subscription" ? "trialing" : "active", result.subscription.state)
      end
    end
  end

  test "lifecycle projection is root isolated, idempotent, append-only, and provider neutral" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    intent = create_intent(graph, country: "IT", key: "project-idempotently").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    first = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                     root_recording: graph[:customer_root])
    repeated = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                        root_recording: graph[:customer_root])
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))

    assert first.projected?
    assert repeated.existing?
    assert_equal 1, RecordingStudioBilling::SubscriptionLine.where(
      subscription_recording_id: first.subscription.recording.id
    ).count
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::SubscriptionLine.where(id: first.subscription.lines.sole.id).update_all(amount_minor: 1)
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Subscription.where(id: first.subscription.id).update_all(state: "paused")
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: other_root)
    end
    source = File.read(Rails.root.join("../../app/services/recording_studio_billing/project_completed_checkout_intent.rb"))
    refute_match(/Stripe::|stripe_credential|:stripe/, source)
  end

  test "base plan variants replace one product line while recurring add-ons remain active" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    annual, = published_option(graph, product_recording: graph[:option].product_recording, kind: "plan",
                                      recurrence: "recurring", interval: "year")
    addon, = published_option(graph, kind: "addon", recurrence: "recurring", interval: "month",
                                     price_feature_values: { "projects" => 8, "seats" => 2 })
    plan_intent = create_intent(graph, country: "IT", key: "base-monthly").intent
    addon_intent = create_intent(graph, country: "IT", key: "recurring-addon", option: addon).intent

    [plan_intent, addon_intent].each do |intent|
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
      RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                               root_recording: graph[:customer_root])
    end
    replacement_intent = create_intent(graph, country: "IT", key: "base-annual", option: annual).intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: replacement_intent,
                                                   root_recording: graph[:customer_root])
    subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: replacement_intent,
                                                                            root_recording: graph[:customer_root]).subscription

    snapshots = RecordingStudioBilling::SubscriptionLine.where(subscription_recording_id: subscription.recording.id)
    plan_snapshots = snapshots.where(product_recording_id: graph[:option].product_recording_id).order(:created_at, :id)
    addon_snapshots = snapshots.where(billing_option_recording_id: addon.recording.id)

    assert_equal [graph[:option].recording.id, annual.recording.id],
                 plan_snapshots.pluck(:billing_option_recording_id)
    assert_equal [graph[:option].product_recording_id], plan_snapshots.pluck(:line_key).uniq
    assert_nil plan_snapshots.first.recording
    assert_equal plan_snapshots.last.id, subscription.lines.find_by(line_key: graph[:option].product_recording_id).id
    assert_equal addon_snapshots.sole.id, addon_snapshots.sole.current.id
    assert_equal 2, subscription.active_lines.count
    assert_equal 2, subscription.active_lines.distinct.count(:line_key)
  end

  test "subscription lifecycle transitions are explicit and reject terminal or invalid moves" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month", trial_days: 7)
    intent = create_intent(graph, country: "IT", key: "lifecycle-transitions").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                            root_recording: graph[:customer_root]).subscription

    assert_equal "active",
                 RecordingStudioBilling::SubscriptionLifecycle.activate(subscription:,
                                                                        root_recording: graph[:customer_root]).state
    assert_equal "paused",
                 RecordingStudioBilling::SubscriptionLifecycle.pause(subscription:,
                                                                     root_recording: graph[:customer_root]).state
    assert_equal "active",
                 RecordingStudioBilling::SubscriptionLifecycle.resume(subscription:,
                                                                      root_recording: graph[:customer_root]).state
    assert_equal "cancelled",
                 RecordingStudioBilling::SubscriptionLifecycle.cancel(subscription:,
                                                                      root_recording: graph[:customer_root]).state
    assert_raises(ArgumentError) { RecordingStudioBilling::SubscriptionLifecycle.resume(subscription:, root_recording: graph[:customer_root]) }
  end

  test "projecting a later checkout reactivates a cancelled execution-group subscription" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    subscription = project_subscription!(graph, key: "before-cancel")
    use_subscription_change_adapter!
    cancel = create_subscription_change!(subscription, graph, key: "cancel-then-buy", kind: "cancellation")
    complete_subscription_change!(cancel)
    RecordingStudioBilling.apply_subscription_change_intent(subscription_change_intent: cancel,
                                                            root_recording: graph[:customer_root])

    assert_equal "cancelled", subscription.current.state
    assert_equal 0, subscription.active_lines.count

    repurchase = project_subscription!(graph, key: "after-cancel")

    assert_equal subscription.current_recording.id, repurchase.current_recording.id
    assert_equal subscription.identifier, repurchase.identifier
    assert_equal "active", repurchase.state
    assert_equal "active", repurchase.lines.sole.state
    assert_equal 1, repurchase.active_lines.count
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
    subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                            root_recording: graph[:customer_root]).subscription

    assert_equal 4, RecordingStudioBilling::EntitlementGrant.where(root_recording: graph[:customer_root]).count
    assert RecordingStudioBilling.entitled?(root_recording: graph[:customer_root], feature_key: "enabled")
    assert_equal 3, RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "projects")
    assert_equal "pro",
                 RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "edition")
    assert_equal({ "edition" => "pro", "enabled" => true, "projects" => 3, "seats" => 5 },
                 RecordingStudioBilling.effective_entitlements(root_recording: graph[:customer_root]))

    replay = RecordingStudioBilling.project_entitlements(root_recording: graph[:customer_root])
    assert_equal 4, replay.grants.count
    assert_equal 4, RecordingStudioBilling::EntitlementGrant.where(root_recording: graph[:customer_root]).count

    RecordingStudioBilling::SubscriptionLifecycle.pause(subscription:, root_recording: graph[:customer_root])
    assert_equal({}, RecordingStudioBilling.effective_entitlements(root_recording: graph[:customer_root]))
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::EntitlementGrant.where(root_recording: graph[:customer_root]).first.update_column(:value, false)
    end
    source = File.read(Rails.root.join("../../app/services/recording_studio_billing/project_entitlements.rb"))
    refute_match(/Stripe::|stripe_credential|:stripe/, source)
  end

  test "checkout projection entitles the root without a separate project_entitlements call" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    intent = create_intent(graph, country: "IT", key: "auto-entitle-checkout").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])

    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                             root_recording: graph[:customer_root])

    assert RecordingStudioBilling.entitled?(root_recording: graph[:customer_root], feature_key: "enabled")
    assert_equal 3, RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "projects")

    replay = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                      root_recording: graph[:customer_root])
    assert replay.existing?
    assert_equal 4, RecordingStudioBilling::EntitlementGrant.where(root_recording: graph[:customer_root]).count
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

    assert_equal 10,
                 RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "projects")
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

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "projects")
    end
    assert_match(/replace values conflict/, error.message)
  end

  test "one-off purchases record under the account, stay immutable, and replay without duplicating" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "credit_pack", recurrence: "one_time", interval: nil)
    intent = create_intent(graph, country: "IT", key: "purchase-recordable").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    first = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                     root_recording: graph[:customer_root])
    repeated = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                        root_recording: graph[:customer_root])
    purchase = first.purchase
    recording = purchase.recording

    assert first.projected?
    assert repeated.existing?
    assert_equal purchase.id, repeated.purchase.id
    assert_equal 1, RecordingStudioBilling::Purchase.for_root(graph[:customer_root]).count
    assert_equal graph[:account_recording].id, recording.parent_recording_id
    assert_equal recording.id, purchase.to_param
    assert_equal recording, RecordingStudioBilling::Purchase.recording_for(purchase.id)
    assert_equal purchase.id, purchase.current.id
    assert_predicate recording.events.where(action: "created"), :one?
    assert_predicate graph[:account_recording].events.where(action: "purchase_completed"), :one?

    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Purchase.where(id: purchase.id).update_all(quantity: 99)
    end

    grant = RecordingStudioBilling::EntitlementGrant.find_by!(source_id: purchase.id)
    entry = RecordingStudioBilling::CreditLedgerEntry.sole

    assert_equal "RecordingStudioBilling::Purchase", grant.source_type
    assert_equal purchase.id, entry.purchase_id
    assert_equal purchase.completed_at, entry.effective_at

    assert_equal recording, RecordingStudioBilling::Purchase.recording_for(recording)
    assert_equal recording, RecordingStudioBilling::Purchase.recording_for(purchase)
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other purchase root #{SecureRandom.hex(4)}"))
    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioBilling::Purchase.recording_for(purchase, root_recording: other_root)
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Purchase.connection.execute(
        "DELETE FROM recording_studio_billing_purchases WHERE id = #{RecordingStudioBilling::Purchase.connection.quote(purchase.id)}"
      )
    end
  end

  test "credit-pack projection is idempotent and the ledger rejects forged facts" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "credit_pack", recurrence: "one_time", interval: nil)
    intent = create_intent(graph, country: "IT", key: "credit-pack").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                        root_recording: graph[:customer_root]).purchase

    entry = RecordingStudioBilling::CreditLedgerEntry.sole

    assert_equal 5,
                 RecordingStudioBilling.credit_balance(root_recording: graph[:customer_root],
                                                       product_recording: purchase.product_recording_id)
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
    assert_equal 2,
                 RecordingStudioBilling::UsageEvent.where(root_recording: graph[:customer_root],
                                                          usage_key: "seats").count
    assert_equal 5, RecordingStudioBilling.usage_total(root_recording: graph[:customer_root], usage_key: "seats")
  end

  test "a delayed worker with an earlier captured timestamp cannot bypass the locked allowance total" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    project_subscription!(graph, key: "reversed-usage-entitlement")
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
    purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                        root_recording: graph[:customer_root]).purchase

    created = RecordingStudioBilling.consume_credits(root_recording: graph[:customer_root], product_recording: purchase.product_recording_id,
                                                     amount: 3, usage_key: "seats", idempotency_key: "consume-once")
    existing = RecordingStudioBilling.consume_credits(root_recording: graph[:customer_root], product_recording: purchase.product_recording_id,
                                                      amount: 3, usage_key: "seats", idempotency_key: "consume-once")

    assert created.created?
    assert existing.existing?
    assert_equal created.entry.id, existing.entry.id
    assert_equal(-3, created.entry.amount)
    assert_equal 2,
                 RecordingStudioBilling.credit_balance(root_recording: graph[:customer_root],
                                                       product_recording: purchase.product_recording_id)
    assert_raises(ActiveRecord::StatementInvalid) { created.entry.update_column(:amount, -4) }
    usage = RecordingStudioBilling.record_usage(root_recording: graph[:customer_root], usage_key: "seats", quantity: 1,
                                                idempotency_key: "forged-oversized-debit").event
    oversized_debit = created.entry.attributes.except("id", "created_at", "updated_at").merge(
      "id" => SecureRandom.uuid, "purchase_id" => nil, "usage_event_id" => usage.id,
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
    purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                                        root_recording: graph[:customer_root]).purchase
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
    assert_equal 0,
                 RecordingStudioBilling.credit_balance(root_recording: graph[:customer_root],
                                                       product_recording: purchase.product_recording_id)
  end

  test "public entitlement APIs normalize an account child recording and fail closed across roots" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    intent = create_intent(graph, country: "IT", key: "normalized-root").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                             root_recording: graph[:customer_root])
    account_child = RecordingStudioBilling::Account.with_current_recording.find_by!(root_recording: graph[:customer_root]).recording
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: other_root, name: "Other account")

    assert RecordingStudioBilling.entitled?(root_recording: account_child, feature_key: "enabled")
    assert_equal 3, RecordingStudioBilling.feature_value(root_recording: account_child, feature_key: "projects")
    assert_equal "pro", RecordingStudioBilling.effective_entitlements(root_recording: account_child).fetch("edition")
    assert_equal 0,
                 RecordingStudioBilling.credit_balance(root_recording: account_child,
                                                       product_recording: SecureRandom.uuid)
    assert_equal({}, RecordingStudioBilling.effective_entitlements(root_recording: other_root))
    refute RecordingStudioBilling.entitled?(root_recording: other_root, feature_key: "enabled")
    assert_nil RecordingStudioBilling.feature_value(root_recording: other_root, feature_key: "projects")
  end

  test "entitlement and credit ledger triggers reject forged source facts" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "credit_pack", recurrence: "one_time", interval: nil)
    intent = create_intent(graph, country: "IT", key: "trigger-facts").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                             root_recording: graph[:customer_root])
    grant = RecordingStudioBilling::EntitlementGrant.first
    entry = RecordingStudioBilling::CreditLedgerEntry.sole
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    other_account = RecordingStudioBilling.ensure_account(root_recording: other_root, name: "Other account").recording

    [{ "value" => false }, { "merge_rule" => "maximum" }, { "root_recording_id" => other_root.id, "account_recording_id" => other_account.id },
     { "source_type" => "RecordingStudioBilling::SubscriptionLine" }].each do |changes|
      assert_raises(ActiveRecord::StatementInvalid) { insert_grant!(grant, changes) }
    end
    assert_raises(ActiveRecord::StatementInvalid) { grant.update_column(:feature_key, "forged") }
    assert_raises(ActiveRecord::StatementInvalid) { insert_ledger!(entry, "amount" => entry.amount + 1) }
    assert_raises(ActiveRecord::StatementInvalid) { insert_ledger!(entry, "product_recording_id" => SecureRandom.uuid) }
    assert_raises(ActiveRecord::StatementInvalid) { insert_ledger!(entry, "root_recording_id" => other_root.id, "account_recording_id" => other_account.id) }
    RecordingStudioBilling.configuration.reset_registries!
    addon_graph = published_catalogue(kind: "addon", recurrence: "one_time", interval: nil)
    addon_intent = create_intent(addon_graph, country: "IT", key: "non-credit-purchase").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: addon_intent,
                                                   root_recording: addon_graph[:customer_root])
    purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: addon_intent,
                                                                        root_recording: addon_graph[:customer_root]).purchase
    forged = entry.attributes.except("id", "created_at", "updated_at").merge("id" => SecureRandom.uuid,
                                                                             "purchase_id" => purchase.id, "root_recording_id" => purchase.root_recording_id, "account_recording_id" => purchase.account_recording_id,
                                                                             "product_recording_id" => purchase.product_recording_id, "manifest_digest" => purchase.manifest_digest, "created_at" => Time.current, "updated_at" => Time.current)
    assert_raises(ActiveRecord::StatementInvalid) { RecordingStudioBilling::CreditLedgerEntry.insert_all!([forged]) }
  end

  test "one-off add-on grants remain effective while terminal subscriptions do not" do
    RecordingStudioBilling.configuration.feature_definitions = entitlement_features
    graph = published_catalogue(kind: "addon", recurrence: "one_time", interval: nil)
    intent = create_intent(graph, country: "IT", key: "one-off-addon").intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                             root_recording: graph[:customer_root])
    assert RecordingStudioBilling.entitled?(root_recording: graph[:customer_root], feature_key: "enabled")

    { paused: :pause, cancelled: :cancel, expired: :expire }.each do |state, transition|
      RecordingStudioBilling.configuration.reset_registries!
      subscription_graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
      subscription_intent = create_intent(subscription_graph, country: "IT", key: "terminal-#{state}").intent
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: subscription_intent,
                                                     root_recording: subscription_graph[:customer_root])
      subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: subscription_intent,
                                                                              root_recording: subscription_graph[:customer_root]).subscription
      RecordingStudioBilling::SubscriptionLifecycle.public_send(transition, subscription:,
                                                                            root_recording: subscription_graph[:customer_root])
      assert_equal({},
                   RecordingStudioBilling.effective_entitlements(root_recording: subscription_graph[:customer_root]))
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

    assert_raises(RecordingStudioBilling::EntitlementAccess::AmbiguousVariant) do
      RecordingStudioBilling.feature_value(root_recording: graph[:customer_root], feature_key: "edition")
    end
  end

  test "subscription cancellation and resumption apply only after completed provider commands and preserve item history" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    subscription = project_subscription!(graph, key: "subscription-change-initial")
    use_subscription_change_adapter!
    original_line = subscription.lines.sole
    line_key = original_line.line_key
    snapshots = RecordingStudioBilling::SubscriptionLine.where(subscription_recording_id: subscription.recording.id,
                                                               line_key:)

    cancellation = create_subscription_change!(subscription, graph, key: "cancel", kind: "cancellation")
    complete_subscription_change!(cancellation)
    cancelled = RecordingStudioBilling::ApplySubscriptionChangeIntent.call(
      subscription_change_intent: cancellation, root_recording: graph[:customer_root]
    )

    assert_equal "applied", cancelled.state
    assert_equal "cancelled", subscription.current.state
    assert_equal "cancelled", original_line.current.state
    assert_nil original_line.reload.recording
    assert_equal 2, snapshots.count

    resumption = create_subscription_change!(subscription, graph, key: "resume", kind: "resumption")
    assert_equal original_line.manifest_digest,
                 resumption.frozen_terms.dig("current_items", line_key, "manifest_digest")
    manifest = RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: original_line.manifest_digest)
    assert_equal manifest_envelope(manifest), resumption.frozen_terms.dig("current_items", line_key)
    complete_subscription_change!(resumption)
    resumed = RecordingStudioBilling::ApplySubscriptionChangeIntent.call(
      subscription_change_intent: resumption, root_recording: graph[:customer_root]
    )

    active_line = original_line.current
    assert_equal "applied", resumed.state
    assert_equal "active", subscription.current.state
    assert_equal "active", active_line.state
    assert_equal 3, snapshots.count
    assert_equal resumption.frozen_terms.fetch("current"), active_line.commercial_snapshot
    assert_equal original_line.manifest_digest, active_line.manifest_digest
    assert_equal resumed.id, RecordingStudioBilling::ApplySubscriptionChangeIntent.call(
      subscription_change_intent: resumed, root_recording: graph[:customer_root]
    ).id
    assert_equal 3, snapshots.count
  end

  test "unresolved, failed, and cross-root subscription changes do not mutate current terms" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    subscription = project_subscription!(graph, key: "subscription-change-unapplied")
    use_subscription_change_adapter!
    original_line = subscription.lines.sole
    change = create_subscription_change!(subscription, graph, key: "failed", kind: "cancellation")

    change.financial_command.update!(state: "failed", normalized_result: { "reason" => "provider_rejected" })
    assert_raises(ArgumentError) do
      RecordingStudioBilling::ApplySubscriptionChangeIntent.call(subscription_change_intent: change,
                                                                 root_recording: graph[:customer_root])
    end
    assert_equal "active", subscription.current.state
    assert_equal original_line.id, subscription.lines.sole.id
    assert_equal "failed", change.reload.state

    review = create_subscription_change!(subscription, graph, key: "review", kind: "cancellation")
    review.financial_command.update!(state: "requires_reconciliation",
                                     normalized_result: { "reason" => "provider_unknown" })
    assert_raises(ArgumentError) do
      RecordingStudioBilling::ApplySubscriptionChangeIntent.call(subscription_change_intent: review,
                                                                 root_recording: graph[:customer_root])
    end
    assert_equal "requires_review", review.reload.state
    assert_equal "active", subscription.current.state
    assert_equal original_line.id, subscription.lines.sole.id

    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Other #{SecureRandom.hex(4)}"))
    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioBilling::ApplySubscriptionChangeIntent.call(subscription_change_intent: change,
                                                                 root_recording: other_root)
    end
  end

  test "plan updates build trusted changes and atomically hold every target when one provider command requires review" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    first_subscription = project_subscription!(graph, key: "plan-update-first")
    second_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Second customer #{SecureRandom.hex(4)}"))
    second_account = record_child(
      RecordingStudioBilling::Account.new(root_recording: second_root, name: "Second customer account", billing_country_code: "IT"),
      second_root, second_root
    )
    second_subscription = project_subscription!(graph.merge(customer_root: second_root, account_recording: second_account),
                                                key: "plan-update-second")
    use_subscription_change_adapter!
    manifest = RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: first_subscription.lines.sole.manifest_digest)
    update = record_child(
      RecordingStudioBilling::PlanUpdate.new(
        billing_option_recording: graph[:option].recording, key: "update_#{SecureRandom.hex(4)}", allowance_policy: "preserve",
        execution_state: "draft", replacement_manifest_digest: manifest.manifest_digest,
        replacement_configuration: { "audience" => { "root_recording_ids" => [graph[:customer_root].id, second_root.id] } }
      ), graph[:provider_root], graph[:admin].recording
    ).recordable

    preview = RecordingStudioBilling::ApplyPlanUpdate.call(plan_update: update, root_recording: graph[:provider_root],
                                                           idempotency_key: "plan-update-run")
    run = RecordingStudioBilling::ApplyPlanUpdate.call(
      run: preview, root_recording: graph[:provider_root], idempotency_key: "plan-update-run", confirmation: { "approved_by" => "admin-1" }
    )
    applications = run.applications.includes(subscription_change_intent: :financial_command).order(:subscription_recording_id).to_a

    assert_equal 2, applications.size
    assert(applications.all? { |application| application.subscription_change_intent.change_set.empty? })
    assert(applications.all? do |application|
      application.subscription_change_intent.frozen_terms.dig("plan_update", "allowance_policy") == "preserve"
    end)
    assert(applications.all? { |application| application.subscription_change_intent.financial_command.present? })
    refute_match(/unsupported input/, run.reconciliation.to_s)

    RecordingStudioBilling::FinancialCommandExecutor.execute(
      command: applications.first.subscription_change_intent.financial_command, provider_key: "fake"
    )
    RecordingStudioBilling::ApplyPlanUpdate.call(run:, root_recording: graph[:provider_root],
                                                 idempotency_key: run.idempotency_key)

    assert_equal "requires_review", run.reload.state
    [first_subscription, second_subscription].each do |subscription|
      assert_equal 1, subscription.active_lines.count
      assert_equal 1, RecordingStudioBilling::SubscriptionLine.where(
        subscription_recording_id: subscription.recording.id
      ).count
    end
  end

  test "plan updates atomically append one trusted version for every ready target" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    first_subscription = project_subscription!(graph, key: "plan-update-success-first")
    second_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Second customer #{SecureRandom.hex(4)}"))
    second_account = record_child(
      RecordingStudioBilling::Account.new(root_recording: second_root, name: "Second customer account", billing_country_code: "IT"),
      second_root, second_root
    )
    second_subscription = project_subscription!(graph.merge(customer_root: second_root, account_recording: second_account),
                                                key: "plan-update-success-second")
    use_subscription_change_adapter!
    manifest = RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: first_subscription.lines.sole.manifest_digest)
    update = record_child(
      RecordingStudioBilling::PlanUpdate.new(
        billing_option_recording: graph[:option].recording, key: "update_#{SecureRandom.hex(4)}", allowance_policy: "preserve",
        execution_state: "draft", replacement_manifest_digest: manifest.manifest_digest,
        replacement_configuration: { "audience" => { "root_recording_ids" => [graph[:customer_root].id, second_root.id] } }
      ), graph[:provider_root], graph[:admin].recording
    ).recordable
    prior_lines = [first_subscription, second_subscription].to_h do |subscription|
      [subscription.recording.id, subscription.lines.sole]
    end

    preview = RecordingStudioBilling::ApplyPlanUpdate.call(plan_update: update, root_recording: graph[:provider_root],
                                                           idempotency_key: "plan-update-success")
    run = RecordingStudioBilling::ApplyPlanUpdate.call(
      run: preview, root_recording: graph[:provider_root], idempotency_key: "plan-update-success", confirmation: { "approved_by" => "admin-1" }
    )
    applications = run.applications.includes(subscription_change_intent: :financial_command).order(:subscription_recording_id).to_a
    applications.each do |application|
      RecordingStudioBilling::FinancialCommandExecutor.execute(
        command: application.subscription_change_intent.financial_command, provider_key: "fake"
      )
    end

    applied = RecordingStudioBilling::ApplyPlanUpdate.call(run:, root_recording: graph[:provider_root],
                                                           idempotency_key: run.idempotency_key)

    assert_equal "applied", applied.state
    assert(applications.all? { |application| application.reload.state == "applied" })
    [first_subscription, second_subscription].each do |subscription|
      snapshots = RecordingStudioBilling::SubscriptionLine
                  .where(subscription_recording_id: subscription.recording.id).order(:created_at, :id).to_a
      prior = prior_lines.fetch(subscription.recording.id).reload
      current = subscription.lines.sole

      assert_equal 2, snapshots.size
      assert_nil prior.recording
      assert_equal current.id, snapshots.last.id
      assert_equal "subscription_change", current.source_type
      application = applications.find { |entry| entry.subscription_recording_id == subscription.recording.id }
      assert_equal application.subscription_change_intent_id, current.source_id
      assert_equal "preserve",
                   application.subscription_change_intent.frozen_terms.dig("plan_update", "allowance_policy")
    end

    replayed = RecordingStudioBilling::ApplyPlanUpdate.call(run:, root_recording: graph[:provider_root],
                                                            idempotency_key: run.idempotency_key)

    assert_equal applied.id, replayed.id
    assert_equal 4,
                 RecordingStudioBilling::SubscriptionLine.where(
                   subscription_recording_id: [first_subscription.recording.id, second_subscription.recording.id]
                 ).count
  end

  test "direct subscription changes reject incompatible proposed manifests before creating commands" do
    graph = published_catalogue(kind: "plan", recurrence: "recurring", interval: "month")
    subscription = project_subscription!(graph, key: "proposal-boundary")
    use_subscription_change_adapter!
    current_manifest = RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: subscription.lines.sole.manifest_digest)
    option_id = graph[:option].recording.id
    command_count = RecordingStudioBilling::FinancialCommand.where(root_recording: graph[:customer_root]).count

    compatible = RecordingStudioBilling::CreateSubscriptionChangeIntent.call(
      subscription:, root_recording: graph[:customer_root], local_idempotency_key: "compatible", change_kind: "interval",
      change_set: { billing_option_recording_id: option_id, quantity: 1 }, proposed_manifest: current_manifest
    ).intent
    assert_equal "fake", compatible.provider_decision.fetch("adapter_key")
    assert_equal subscription.currency_code,
                 compatible.frozen_terms.dig("proposed", "canonical_data", "price", "currency_code")
    assert_equal subscription.market_recording_id,
                 compatible.frozen_terms.dig("proposed", "canonical_data", "trusted_context", "market_recording_id")
    assert_equal command_count + 1,
                 RecordingStudioBilling::FinancialCommand.where(root_recording: graph[:customer_root]).count

    incompatible_manifests = {
      currency: forged_manifest(current_manifest) { |terms| terms.fetch("price")["currency_code"] = "USD" },
      collection_method: forged_manifest(current_manifest) do |terms|
        terms.fetch("billing_option")["collection_method"] = "send_invoice"
      end,
      payment_terms: forged_manifest(current_manifest) do |terms|
        terms.fetch("billing_option")["payment_terms_days"] = 30
      end,
      market: forged_manifest(current_manifest) do |terms|
        terms.fetch("trusted_context")["market_recording_id"] = SecureRandom.uuid
      end,
      interval: forged_manifest(current_manifest) do |terms|
        terms.fetch("billing_option").merge!("interval" => "year", "interval_count" => 1)
      end
    }
    incompatible_manifests.each do |name, manifest|
      assert_rejects_proposed_manifest(subscription, graph, manifest, key: "incompatible-#{name}", option_id:)
    end

    other_provider_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Other provider #{SecureRandom.hex(4)}"))
    other_admin = RecordingStudioBilling.ensure_billing_admin(root_recording: other_provider_root,
                                                              key: "billing_#{SecureRandom.hex(4)}")
    other_provider = record_child(
      RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: other_admin.recording, key: "provider_#{SecureRandom.hex(4)}",
                                                  adapter_key: "fake", name: "Other", environment: "test", configuration: {}, capabilities: [], supported_markets: ["IT"], supported_currencies: ["EUR"]),
      other_provider_root, other_admin.recording
    )
    foreign_provider_manifest = forged_manifest(current_manifest, root_recording_id: other_provider_root.id) do |terms|
      terms.fetch("usage_settlement")["provider_account_recording_id"] = other_provider.id
    end
    assert_rejects_proposed_manifest(subscription, graph, foreign_provider_manifest, key: "foreign-provider",
                                                                                     option_id:)

    rule = record_child(
      RecordingStudioBilling::ProductRule.new(product_recording: graph[:option].product_recording, target_product_recording: graph[:option].product_recording,
                                              key: "self_excludes_#{SecureRandom.hex(4)}", rule_type: "excludes", conditions: { "country_code" => "IT" }),
      graph[:provider_root], graph[:admin].recording
    )
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:provider_root],
                                                         price_recording_ids: [graph[:italy_price].recording.id], actor: @actor)
    rule_manifest = RecordingStudioBilling::CommercialManifest.where(root_recording_id: graph[:provider_root].id).order(created_at: :desc).find do |manifest|
      manifest.canonical_data.fetch("product_rules").any? { |entry| entry["key"] == rule.recordable.key }
    end
    assert_rejects_proposed_manifest(subscription, graph, rule_manifest, key: "rule-conflict", option_id:)
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

  def create_intent(graph, country:, key:, option: graph[:option], presentation: nil)
    RecordingStudioBilling.create_checkout_intent(
      root_recording: graph[:customer_root], local_idempotency_key: key, country_code: country,
      presentation:, items: [{ billing_option_recording_id: option.recording.id, quantity: 1 }]
    )
  end

  def project_subscription!(graph, key:)
    intent = create_intent(graph, country: "IT", key:).intent
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: graph[:customer_root])
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent,
                                                             root_recording: graph[:customer_root]).subscription
  end

  def create_subscription_change!(subscription, graph, key:, kind:)
    RecordingStudioBilling::CreateSubscriptionChangeIntent.call(
      subscription:, root_recording: graph[:customer_root], local_idempotency_key: key, change_kind: kind
    ).intent
  end

  def complete_subscription_change!(intent)
    RecordingStudioBilling::FinancialCommandExecutor.execute(command: intent.financial_command, provider_key: "fake")
    assert_equal "succeeded", intent.financial_command.reload.state
  end

  def use_subscription_change_adapter!
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider("fake",
                                             RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success))
  end

  def assert_rejects_proposed_manifest(subscription, graph, manifest, key:, option_id:)
    before = RecordingStudioBilling::FinancialCommand.where(root_recording: graph[:customer_root]).count
    assert_raises(ArgumentError) do
      RecordingStudioBilling::CreateSubscriptionChangeIntent.call(
        subscription:, root_recording: graph[:customer_root], local_idempotency_key: key, change_kind: "quantity",
        change_set: { billing_option_recording_id: option_id, quantity: 1 }, proposed_manifest: manifest
      )
    end
    assert_equal before, RecordingStudioBilling::FinancialCommand.where(root_recording: graph[:customer_root]).count
  end

  def forged_manifest(source, root_recording_id: source.root_recording_id)
    canonical_data = source.canonical_data.deep_dup
    yield canonical_data
    envelope = {
      "schema_version" => source.schema_version, "resolver_version" => source.resolver_version, "root_recording_id" => root_recording_id,
      "canonical_data" => canonical_data, "recording_snapshots" => source.recording_snapshots, "snapshot_references" => source.snapshot_references
    }
    RecordingStudioBilling::CommercialManifest.create!(root_recording_id:, schema_version: source.schema_version,
                                                       resolver_version: source.resolver_version, canonical_data:,
                                                       recording_snapshots: source.recording_snapshots,
                                                       snapshot_references: source.snapshot_references,
                                                       manifest_digest: RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope), used_at: Time.current)
  end

  def manifest_envelope(manifest)
    {
      "manifest_digest" => manifest.manifest_digest, "schema_version" => manifest.schema_version,
      "resolver_version" => manifest.resolver_version, "root_recording_id" => manifest.root_recording_id,
      "canonical_data" => manifest.canonical_data, "recording_snapshots" => manifest.recording_snapshots,
      "snapshot_references" => manifest.snapshot_references
    }
  end

  def published_catalogue(kind: "service", recurrence: "one_time", interval: nil, trial_days: 0, amount: 1_000,
                          account_country: "IT", checkout_policy: "allowed", germany_verification_policy: "requote",
                          checkout_modes: ["redirect"])
    provider_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: provider_root,
                                                        key: "billing_#{SecureRandom.hex(4)}")
    provider_recording = record_child(
      RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}",
                                                  adapter_key: "fake", name: "Fake", environment: "test", configuration: {}, capabilities: [], supported_markets: %w[IT DE], supported_currencies: ["EUR"]),
      provider_root, admin.recording
    )
    italy_market = market("italy", "IT", provider_recording, provider_root, admin.recording, "requote")
    germany_market = market("germany", "DE", provider_recording, provider_root, admin.recording,
                            germany_verification_policy)
    graph = { provider_root:, admin:, provider_recording:, italy_market:, germany_market: }
    option, published_italy_price, published_germany_price = published_option(graph, kind:, recurrence:, interval:,
                                                                                     trial_days:, amount:, checkout_policy:)
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success,
                                                               capabilities: RecordingStudioBilling::ProviderCapabilities.new(operations: ["checkout"], currencies: ["EUR"],
                                                                                                                              markets: %w[IT DE], collection_methods: ["automatic"], checkout_modes:, quantities: ["fixed"], composition: ["single"]))
    RecordingStudioBilling.register_provider("fake", adapter)
    customer_root = RecordingStudio.root_recording_for(Workspace.create!(name: "Customer #{SecureRandom.hex(4)}"))
    account_recording = record_child(
      RecordingStudioBilling::Account.new(root_recording: customer_root, name: "Customer account",
                                          billing_country_code: account_country),
      customer_root, customer_root
    )
    graph.merge(customer_root:, account_recording:, option:, italy_price: published_italy_price, germany_price: published_germany_price,
                adapter:)
  end

  def verified_country(country_code, source)
    RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new(country_code, source)
  end

  def published_option(graph, kind:, recurrence:, interval:, product_recording: nil, trial_days: 0, amount: 1_000,
                       option_feature_values: {}, price_feature_values: {}, checkout_policy: "allowed")
    product_recording ||= record_child(
      RecordingStudioBilling::Product.new(provider_account_recording: graph[:provider_recording],
                                          key: "product_#{SecureRandom.hex(4)}", kind:, feature_values: {}), graph[:provider_root], graph[:admin].recording
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
    italy_price = price("italy", option_recording, graph[:italy_market], amount, graph[:provider_root],
                        price_feature_values)
    germany_price = price("germany", option_recording, graph[:germany_market], amount + 200, graph[:provider_root],
                          price_feature_values)
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:provider_root],
                                                         price_recording_ids: [italy_price.id, germany_price.id], actor: @actor)
    [
      current_recordable(option_recording, RecordingStudioBilling::BillingOption),
      current_recordable(italy_price, RecordingStudioBilling::Price),
      current_recordable(germany_price, RecordingStudioBilling::Price)
    ]
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
      "enabled" => { source: "catalogue", merge_rule: "replace", default: true, type: "boolean", meter_key: nil,
                     usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 1, validation: {} },
      "projects" => { source: "catalogue", merge_rule: "replace", default: 3, type: "limit", meter_key: nil,
                      usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 2, validation: { "minimum" => 0 } },
      "seats" => { source: "catalogue", merge_rule: "replace", default: 5, type: "allowance", meter_key: nil,
                   usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 3, validation: { "minimum" => 0 } },
      "edition" => { source: "catalogue", merge_rule: "replace", default: "pro", type: "variant", meter_key: nil,
                     usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 4, validation: {} }
    }
  end
end
