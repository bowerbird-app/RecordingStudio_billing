# frozen_string_literal: true

require "test_helper"

class StripeAdapterTest < Minitest::Test
  def test_capabilities_use_the_shared_generic_contract
    adapter = RecordingStudioBilling::StripeAdapter.new
    checkout = adapter.capabilities.evaluate(operation: :checkout, checkout_mode: :embedded)
    charge = adapter.capabilities.evaluate(operation: :charge)

    assert_instance_of RecordingStudioBilling::ProviderCapabilities, adapter.capabilities
    assert_predicate checkout, :supported?
    refute charge.supported?
    assert_equal "unsupported_operation", charge.reason
  end

  def test_absent_credentials_return_a_normalized_unavailable_response_without_resolving_a_client
    resolver_calls = 0
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      resolver_calls += 1
      nil
    })

    response = adapter.call(command: Object.new, request: {}, idempotency_key: "test-key")

    assert_equal 1, resolver_calls
    assert_equal "provider_unavailable", response.status
    assert_equal "configuration_missing", response.result.fetch("reason")
    assert_equal({ "adapter" => "stripe" }, response.metadata)
  end

  def test_checkout_uses_the_durable_idempotency_key_and_persists_only_an_opaque_reference
    credential = "test-stripe-credential"
    resolver_calls = 0
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    request = {
      "request" => {
        "presentation" => "embedded", "currency" => "USD", "collection_method" => "automatic",
        "checkout_items" => { "item-1" => { "amount_minor" => 1_200, "quantity" => 1, "recurrence" => "one_time" } }
      }
    }
    captured = nil
    response = Struct.new(:id).new("cs_test_123")
    sessions = Object.new
    sessions.define_singleton_method(:create) do |params, options|
      captured = { params:, options: }
      response
    end
    checkout = Struct.new(:sessions).new(sessions)
    client = Struct.new(:v1).new(Struct.new(:checkout).new(checkout))
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: lambda {
        resolver_calls += 1
        credential
      },
      client_factory: ->(_secret) { client }
    )

    assert_equal 0, resolver_calls
    response = adapter.call(command:, request:, idempotency_key: "test-key")

    assert_equal 1, resolver_calls
    assert_equal "pending", response.status
    assert_equal "cs_test_123", response.provider_reference
    assert_equal "test-key", captured.fetch(:options).fetch(:idempotency_key)
    assert_equal 1_200, captured.fetch(:params).fetch("line_items").first.dig("price_data", "unit_amount")
    assert defined?(Stripe)
    refute_includes [response.result, response.error_details, response.metadata].to_s, credential
  end

  def test_subscription_checkout_sends_recurring_price_terms
    captured = nil
    sessions = Object.new
    sessions.define_singleton_method(:create) do |params, _options|
      captured = params
      Struct.new(:id).new("cs_subscription_123")
    end
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { "sk_test" },
      client_factory: ->(_secret) { client }
    )
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    request = {
      "request" => {
        "presentation" => "embedded", "currency" => "USD", "collection_method" => "automatic",
        "checkout_items" => {
          "item-1" => {
            "amount_minor" => 100, "quantity" => 1, "recurrence" => "recurring",
            "interval" => "month", "interval_count" => 1
          }
        }
      }
    }

    response = adapter.call(command:, request:, idempotency_key: "subscription-key")

    assert_equal "pending", response.status
    assert_equal "subscription", captured.fetch("mode")
    assert_equal({ "interval" => "month", "interval_count" => 1 },
                 captured.dig("line_items", 0, "price_data", "recurring"))
  end

  def test_subscription_checkout_rejects_invalid_recurring_terms_before_calling_stripe
    client_calls = 0
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { "sk_test" },
      client_factory: lambda { |_secret|
        client_calls += 1
        raise "Stripe client should not be constructed"
      }
    )
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    request = {
      "request" => {
        "presentation" => "embedded", "currency" => "USD", "collection_method" => "automatic",
        "checkout_items" => {
          "item-1" => {
            "amount_minor" => 100, "quantity" => 1, "recurrence" => "recurring",
            "interval" => "fortnight", "interval_count" => 1
          }
        }
      }
    }

    response = adapter.call(command:, request:, idempotency_key: "invalid-subscription-key")

    assert_equal "invalid", response.status
    assert_equal 0, client_calls
  end

  def test_payment_link_is_an_intent_bound_checkout_session_with_a_transient_url
    captured = nil
    sessions = Object.new
    sessions.define_singleton_method(:create) do |params, options|
      captured = { params:, options: }
      Struct.new(:id).new("cs_payment_link_123")
    end
    sessions.define_singleton_method(:retrieve) do |_reference|
      { "url" => "https://checkout.stripe.com/c/pay/cs_payment_link_123",
        "metadata" => { "recording_studio_billing_presentation" => "payment_link" } }
    end
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      "sk_test"
    }, client_factory: lambda { |_secret|
         client
       })
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    request = { "request" => { "presentation" => "payment_link", "currency" => "USD", "collection_method" => "automatic",
                               "checkout_items" => { "item-1" => { "amount_minor" => 1_200, "quantity" => 1, "recurrence" => "one_time" } } } }

    response = adapter.call(command:, request:, idempotency_key: "durable-key")

    assert_equal "pending", response.status
    assert_equal "cs_payment_link_123", response.provider_reference
    refute captured.fetch(:params).key?("ui_mode")
    assert_equal "payment_link", captured.fetch(:params).dig("metadata", "recording_studio_billing_presentation")
    assert_equal "durable-key", captured.fetch(:options).fetch(:idempotency_key)
    refute_match(/checkout\.stripe\.com|client_secret/, response.result.to_s)
    assert_equal({ mode: "payment_link", url: "https://checkout.stripe.com/c/pay/cs_payment_link_123" },
                 adapter.checkout_presentation(provider_reference: response.provider_reference))
  end

  def test_embedded_checkout_sends_only_frozen_terms_and_exposes_a_transient_client_secret
    captured = nil
    sessions = Object.new
    sessions.define_singleton_method(:create) do |params, options|
      captured = { params:, options: }
      Struct.new(:id).new("cs_embedded_123")
    end
    sessions.define_singleton_method(:retrieve) do |_reference|
      { "ui_mode" => "embedded_page", "client_secret" => "cs_test_secret", "id" => "cs_embedded_123" }
    end
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { { secret_key: "sk_test", publishable_key: "pk_test" } },
      client_factory: ->(_secret) { client }
    )
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    request = { "request" => { "presentation" => "embedded", "currency" => "USD", "collection_method" => "automatic",
                               "checkout_items" => { "frozen-item" => { "amount_minor" => 1_200, "quantity" => 1,
                                                                        "recurrence" => "one_time", "card_number" => "ignored" } } } }

    response = adapter.call(command:, request:, idempotency_key: "durable-key")

    assert_equal "pending", response.status
    assert_equal "embedded_page", captured.fetch(:params).fetch("ui_mode")
    assert_equal "payment", captured.fetch(:params).fetch("mode")
    assert_equal 1_200, captured.fetch(:params).dig("line_items", 0, "price_data", "unit_amount")
    refute_includes captured.fetch(:params).to_s, "card_number"
    refute_match(/client_secret|sk_test|pk_test/, [response.result, response.metadata].inspect)
    assert_equal({ mode: "embedded", client_secret: "cs_test_secret", publishable_key: "pk_test" },
                 adapter.checkout_presentation(provider_reference: response.provider_reference))
  end

  def test_redirect_checkout_maps_to_stripe_hosted_page_ui_mode
    captured = nil
    sessions = Object.new
    sessions.define_singleton_method(:create) do |params, options|
      captured = { params:, options: }
      Struct.new(:id).new("cs_redirect_123")
    end
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: lambda {
        { secret_key: "sk_test", success_url: "https://app.example.test/billing",
          cancel_url: "https://app.example.test/billing" }
      },
      trusted_origins_resolver: -> { ["https://app.example.test"] },
      client_factory: ->(_secret) { client }
    )
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    request = { "request" => { "presentation" => "redirect", "currency" => "USD", "collection_method" => "automatic",
                               "checkout_items" => { "item-1" => { "amount_minor" => 100, "quantity" => 1,
                                                                   "recurrence" => "one_time" } } } }

    response = adapter.call(command:, request:, idempotency_key: "durable-key")

    assert_equal "pending", response.status
    assert_equal "hosted_page", captured.fetch(:params).fetch("ui_mode")
    assert_equal "https://app.example.test/billing", captured.fetch(:params).fetch("success_url")
  end

  def test_checkout_enables_native_stripe_tax_only_from_the_frozen_command_policy
    captured = []
    sessions = Object.new
    sessions.define_singleton_method(:create) do |params, _options|
      captured << params
      Struct.new(:id).new("cs_tax_#{captured.length}")
    end
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { "sk_test" }, tax_code_resolver: ->(category) { "txcd_#{category}" },
      client_factory: ->(_secret) { client }
    )
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    base = { "presentation" => "embedded", "currency" => "USD", "collection_method" => "automatic",
             "checkout_items" => { "item-1" => { "amount_minor" => 1_200, "quantity" => 1 } } }

    adapter.call(command:, request: { "request" => base.merge("tax" => { "enabled" => false }) },
                 idempotency_key: "disabled")
    adapter.call(command:, request: { "request" => base.merge("tax" => {
                                                                "enabled" => true, "mode" => "provider_native", "calculator_key" => "stripe_tax", "behavior" => "exclusive",
                                                                "semantic_categories" => ["standard"], "location_requirements" => ["tax_id"]
                                                              }) }, idempotency_key: "enabled")

    refute captured.first.key?("automatic_tax")
    assert_equal({ "enabled" => true }, captured.last.fetch("automatic_tax"))
    assert_equal "required", captured.last.fetch("billing_address_collection")
    assert_equal({ "enabled" => true }, captured.last.fetch("tax_id_collection"))
    assert_equal "exclusive", captured.last.dig("line_items", 0, "price_data", "tax_behavior")
    assert_equal "txcd_standard", captured.last.dig("line_items", 0, "price_data", "product_data", "tax_code")
    assert_equal "operation-1", captured.last.dig("metadata", "recording_studio_billing_tax_operation")
  end

  def test_completed_checkout_retrieval_normalizes_provider_tax_without_retaining_the_raw_session
    sessions = Object.new
    sessions.define_singleton_method(:retrieve) do |_reference, _params = {}, *_rest|
      {
        "object" => "checkout.session", "payment_status" => "paid", "amount_subtotal" => 1_000,
        "amount_total" => 1_090, "currency" => "usd",
        "total_details" => { "amount_discount" => 0, "amount_tax" => 90 },
        "client_secret" => "must-not-persist", "url" => "https://checkout.stripe.com/session",
        "line_items" => { "data" => [{ "quantity" => 1, "amount_subtotal" => 1_000, "amount_discount" => 0,
                                       "amount_tax" => 90, "amount_total" => 1_090, "currency" => "usd",
                                       "price" => { "unit_amount" => 1_000, "product" => { "metadata" => {
                                         "recording_studio_billing_item" => "item-1", "recording_studio_billing_manifest" => "a" * 64
                                       } } } }] }
      }
    end
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      "sk_test"
    }, client_factory: lambda { |_secret|
         client
       })
    command = Struct.new(:command_type, :provider_reference, :canonical_request).new(
      "checkout", "cs_complete_123", { "request" => { "tax" => { "enabled" => false } } }
    )

    response = adapter.retrieve(command:)

    assert_equal "succeeded", response.fetch(:outcome)
    assert_equal 90, response.fetch(:payload).fetch("tax_minor")
    assert_equal 1_090, response.fetch(:payload).fetch("total_minor")
    assert_equal "item-1", response.fetch(:payload).fetch("lines").sole.fetch("checkout_intent_item_id")
    refute_match(/client_secret|checkout\.stripe\.com|sk_test/, response.fetch(:payload).inspect)
  end

  def test_retrieve_builds_checkout_payload_from_default_session_json_and_line_item_list
    retrieve_calls = []
    list_calls = []
    session = JSON.parse(File.read(File.expand_path("fixtures/stripe_checkout_session_default.json", __dir__)))
    listed = JSON.parse(File.read(File.expand_path("fixtures/stripe_checkout_session_line_items.json", __dir__)))
    sessions = Object.new
    sessions.define_singleton_method(:retrieve) do |reference, params = {}, *_rest|
      retrieve_calls << { reference:, params: }
      session.merge("id" => reference)
    end
    line_items = Object.new
    line_items.define_singleton_method(:list) do |reference, params = {}, *_rest|
      list_calls << { reference:, params: }
      listed.merge("url" => "/v1/checkout/sessions/#{reference}/line_items")
    end
    sessions.define_singleton_method(:line_items) { line_items }
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      "sk_test"
    }, client_factory: lambda { |_secret|
         client
       })
    command = Struct.new(:command_type, :provider_reference, :canonical_request).new(
      "checkout", "cs_test_default", { "request" => { "tax" => { "enabled" => false } } }
    )

    response = adapter.retrieve(command:)

    assert retrieve_calls.one?
    assert_includes Array(retrieve_calls.first.fetch(:params)[:expand] || retrieve_calls.first.fetch(:params)["expand"]),
                    "line_items.data.price.product"
    assert_includes Array(retrieve_calls.first.fetch(:params)[:expand] || retrieve_calls.first.fetch(:params)["expand"]),
                    "subscription"
    assert list_calls.one?
    assert_equal 100, list_calls.first.fetch(:params)[:limit] || list_calls.first.fetch(:params)["limit"]
    assert_equal "succeeded", response.fetch(:outcome)
    assert_equal 90, response.fetch(:payload).fetch("tax_minor")
    assert_equal 0, response.fetch(:payload).fetch("discount_minor")
    assert_equal 1_090, response.fetch(:payload).fetch("total_minor")
    assert_equal "paid", response.fetch(:payload).fetch("payment_state")
    assert_equal "item-1", response.fetch(:payload).fetch("lines").sole.fetch("checkout_intent_item_id")
    refute_match(/client_secret|checkout\.stripe\.com|sk_test/, response.fetch(:payload).inspect)
    %w[subtotal_minor discount_minor tax_minor total_minor currency payment_state lines].each do |key|
      assert response.fetch(:payload).key?(key), key
    end
    line_keys = %w[checkout_intent_item_id manifest_digest currency quantity unit_amount_minor subtotal_minor
                   discount_minor tax_minor total_minor]
    line_keys.each { |key| assert response.fetch(:payload).fetch("lines").sole.key?(key), key }
    assert_equal 1_090, response.fetch(:payload).fetch("subtotal_minor") -
                        response.fetch(:payload).fetch("discount_minor") +
                        response.fetch(:payload).fetch("tax_minor")
  end

  def test_retrieve_copies_prefixed_checkout_identities_and_ignores_the_rest
    retrieve_calls = []
    list_calls = []
    session = JSON.parse(File.read(File.expand_path("fixtures/stripe_checkout_session_default.json", __dir__)))
    listed = JSON.parse(File.read(File.expand_path("fixtures/stripe_checkout_session_line_items.json", __dir__)))
    session = session.merge(
      "subscription" => {
        "id" => "sub_test_paid",
        "object" => "subscription",
        "items" => { "object" => "list", "data" => [{ "id" => "si_from_subscription", "object" => "subscription_item" }] }
      },
      "payment_intent" => "pi_test_paid",
      "invoice" => "in_test_paid",
      "customer" => "cus_must_not_copy",
      "url" => "https://checkout.stripe.com/c/pay/cs_test_default"
    )
    listed["data"][0]["subscription_item"] = "si_from_line"
    sessions = Object.new
    sessions.define_singleton_method(:retrieve) do |reference, params = {}, *_rest|
      retrieve_calls << { reference:, params: }
      session.merge("id" => reference)
    end
    line_items = Object.new
    line_items.define_singleton_method(:list) do |reference, params = {}, *_rest|
      list_calls << { reference:, params: }
      listed.merge("url" => "/v1/checkout/sessions/#{reference}/line_items")
    end
    sessions.define_singleton_method(:line_items) { line_items }
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      "sk_test"
    }, client_factory: lambda { |_secret|
         client
       })
    command = Struct.new(:command_type, :provider_reference, :canonical_request).new(
      "checkout", "cs_test_identities", { "request" => { "tax" => { "enabled" => false } } }
    )

    response = adapter.retrieve(command:)
    payload = response.fetch(:payload)

    assert retrieve_calls.one?
    assert list_calls.one?
    assert_equal "sub_test_paid", payload.fetch("subscription")
    assert_equal "pi_test_paid", payload.fetch("payment_intent")
    assert_equal "in_test_paid", payload.fetch("invoice")
    assert_equal %w[si_from_subscription si_from_line], payload.fetch("subscription_items")
    assert_equal "si_from_line", payload.fetch("lines").sole.fetch("subscription_item")
    refute payload.key?("customer")
    refute payload.key?("url")
    refute_match(/cus_must_not_copy|client_secret|checkout\.stripe\.com|sk_test/, payload.inspect)
  end

  def test_retrieve_omits_checkout_identities_when_prefixes_do_not_match
    session = JSON.parse(File.read(File.expand_path("fixtures/stripe_checkout_session_default.json", __dir__)))
    listed = JSON.parse(File.read(File.expand_path("fixtures/stripe_checkout_session_line_items.json", __dir__)))
    session = session.merge("subscription" => "cus_wrong", "payment_intent" => "in_wrong", "invoice" => "pi_wrong")
    listed["data"][0]["subscription_item"] = "sub_wrong"
    sessions = Object.new
    sessions.define_singleton_method(:retrieve) do |reference, _params = {}, *_rest|
      session.merge("id" => reference)
    end
    line_items = Object.new
    line_items.define_singleton_method(:list) do |reference, _params = {}, *_rest|
      listed.merge("url" => "/v1/checkout/sessions/#{reference}/line_items")
    end
    sessions.define_singleton_method(:line_items) { line_items }
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      "sk_test"
    }, client_factory: lambda { |_secret|
         client
       })
    command = Struct.new(:command_type, :provider_reference, :canonical_request).new(
      "checkout", "cs_test_bad_ids", { "request" => { "tax" => { "enabled" => false } } }
    )

    payload = adapter.retrieve(command:).fetch(:payload)

    refute payload.key?("subscription")
    refute payload.key?("payment_intent")
    refute payload.key?("invoice")
    refute payload.key?("subscription_items")
    refute payload.fetch("lines").sole.key?("subscription_item")
  end

  def test_retrieve_withholds_checkout_payload_when_line_item_list_exceeds_the_bound
    list_calls = []
    session = JSON.parse(File.read(File.expand_path("fixtures/stripe_checkout_session_default.json", __dir__)))
    listed = JSON.parse(File.read(File.expand_path("fixtures/stripe_checkout_session_line_items.json", __dir__)))
    listed["has_more"] = true
    sessions = Object.new
    sessions.define_singleton_method(:retrieve) do |reference, _params = {}, *_rest|
      session.merge("id" => reference)
    end
    line_items = Object.new
    line_items.define_singleton_method(:list) do |reference, params = {}, *_rest|
      list_calls << { reference:, params: }
      listed.merge("url" => "/v1/checkout/sessions/#{reference}/line_items")
    end
    sessions.define_singleton_method(:line_items) { line_items }
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      "sk_test"
    }, client_factory: lambda { |_secret|
         client
       })
    command = Struct.new(:command_type, :provider_reference, :canonical_request).new(
      "checkout", "cs_test_overflow", { "request" => { "tax" => { "enabled" => false } } }
    )

    response = adapter.retrieve(command:)

    assert_equal 1, list_calls.size
    assert_equal 100, list_calls.first.fetch(:params)[:limit] || list_calls.first.fetch(:params)["limit"]
    assert_equal "succeeded", response.fetch(:outcome)
    refute response.fetch(:payload).key?("tax_minor")
    refute response.fetch(:payload).key?("lines")
  end

  def test_unsupported_checkout_presentation_currency_or_collection_never_calls_stripe
    calls = 0
    sessions = Object.new
    sessions.define_singleton_method(:create) { |*_arguments| calls += 1 }
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      "sk_test"
    }, client_factory: lambda { |_secret|
         client
       })
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    base = { "presentation" => "embedded", "currency" => "USD", "collection_method" => "automatic",
             "checkout_items" => { "item-1" => { "amount_minor" => 1_200, "quantity" => 1 } } }

    %w[JPY].each do |currency|
      response = adapter.call(command:, request: { "request" => base.merge("currency" => currency) },
                              idempotency_key: "key-#{currency}")
      assert_equal "unsupported_currency", response.status
    end
    response = adapter.call(command:, request: { "request" => base.merge("collection_method" => "manual") },
                            idempotency_key: "key-manual")
    assert_equal "unsupported", response.status
    response = adapter.call(command:, request: { "request" => base.merge("presentation" => "elements") },
                            idempotency_key: "key-elements")
    assert_equal "unsupported_checkout_mode", response.status
    assert_equal 0, calls
  end

  def test_invoice_presentation_uses_hosted_checkout_with_invoice_creation
    captured = []
    sessions = Object.new
    sessions.define_singleton_method(:create) do |params, _options|
      captured << params
      Struct.new(:id).new("cs_invoice_123")
    end
    sessions.define_singleton_method(:retrieve) do |_reference|
      { "url" => "https://checkout.stripe.com/c/pay/cs_invoice_123",
        "metadata" => { "recording_studio_billing_presentation" => "invoice" } }
    end
    client = Struct.new(:v1).new(Struct.new(:checkout).new(Struct.new(:sessions).new(sessions)))
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      { secret_key: "sk_test", success_url: "https://app.example.test/success",
        cancel_url: "https://app.example.test/cancel" }
    }, client_factory: lambda { |_secret|
         client
       }, trusted_origins_resolver: -> { ["https://app.example.test"] })
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    request = { "request" => { "presentation" => "invoice", "currency" => "USD", "collection_method" => "send_invoice",
                               "payment_terms_days" => 14,
                               "checkout_items" => { "item-1" => { "amount_minor" => 1_200, "quantity" => 1 } } } }

    response = adapter.call(command:, request:, idempotency_key: "durable-invoice")

    assert_equal "pending", response.status
    refute captured.last.key?("ui_mode")
    assert_equal({ "enabled" => true, "invoice_data" => { "collection_method" => "send_invoice", "days_until_due" => 14 } },
                 captured.last.fetch("invoice_creation"))
    assert_equal({ mode: "invoice", url: "https://checkout.stripe.com/c/pay/cs_invoice_123" },
                 adapter.checkout_presentation(provider_reference: response.provider_reference))
  end

  def test_no_charge_requires_zero_frozen_lines_and_never_constructs_a_stripe_client
    client_calls = 0
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> {}, client_factory: ->(_secret) { client_calls += 1 }
    )
    command = Struct.new(:command_type, :operation_id).new("checkout", "operation-1")
    request = { "request" => { "presentation" => "no_charge",
                               "checkout_items" => { "item-1" => { "amount_minor" => 0 } } } }

    response = adapter.call(command:, request:, idempotency_key: "durable-key")

    assert_equal "success", response.status
    assert_nil response.provider_reference
    assert_equal 0, client_calls
    assert_equal "no_charge", response.result.fetch("presentation")
    invalid = adapter.call(command:, request: request.deep_merge("request" => { "checkout_items" => { "item-1" => { "amount_minor" => 1 } } }),
                           idempotency_key: "durable-key")
    assert_equal "invalid", invalid.status
    assert_equal "no_charge_terms_invalid", invalid.result.fetch("reason")
  end

  def test_subscription_changes_require_opaque_stripe_references_and_reuse_the_durable_key
    captured = []
    subscriptions = Object.new
    subscriptions.define_singleton_method(:update) do |reference, params, options|
      captured << { reference:, params:, options: }
      { "id" => reference, "status" => "active" }
    end
    client = Struct.new(:v1).new(Struct.new(:subscriptions).new(subscriptions))
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: lambda {
      "sk_test"
    }, client_factory: lambda { |_secret|
         client
       })
    command = Struct.new(:command_type, :operation_id).new("subscription_change", "operation-1")
    base = { "provider_subscription_reference" => "sub_123", "provider_subscription_item_reference" => "si_123",
             "provider_price_reference" => "price_123", "quantity" => 3 }

    %w[plan interval quantity].each do |kind|
      response = adapter.call(command:, idempotency_key: "durable-key",
                              request: { "request" => { "change_kind" => kind, "change_set" => base, "proration_policy" => "none" } })
      assert_equal "success", response.status, kind
    end
    addon = adapter.call(command:, idempotency_key: "durable-key",
                         request: { "request" => { "change_kind" => "addon", "change_set" => base.merge("addon_action" => "remove"), "proration_policy" => "none" } })
    assert_equal "success", addon.status
    assert_equal({ "items" => [{ "id" => "si_123", "deleted" => true }], "proration_behavior" => "none" },
                 captured.last.fetch(:params))
    assert_equal ["durable-key"], captured.map { |call| call.fetch(:options).fetch(:idempotency_key) }.uniq

    invalid = adapter.call(command:, idempotency_key: "durable-key",
                           request: { "request" => { "change_kind" => "quantity", "change_set" => base.except("provider_subscription_item_reference") } })
    assert_equal "invalid", invalid.status
    assert_equal "subscription_item_reference_missing", invalid.result.fetch("reason")
    assert_equal 4, captured.size
  end

  def test_capabilities_advertise_only_executable_checkout_modes_and_subscription_kinds
    adapter = RecordingStudioBilling::StripeAdapter.new

    %w[embedded redirect payment_link invoice no_charge].each do |mode|
      assert_predicate adapter.capabilities.evaluate(operation: "checkout", checkout_mode: mode), :supported?, mode
    end
    assert_predicate adapter.capabilities.evaluate(operation: "checkout", collection_method: "send_invoice"), :supported?
    assert_predicate adapter.capabilities.evaluate(operation: "checkout", market: "us"), :supported?
    refute adapter.capabilities.evaluate(operation: "checkout", checkout_mode: "elements").supported?
    %w[cancellation resumption plan interval addon quantity].each do |kind|
      assert_predicate adapter.capabilities.evaluate(operation: "subscription_change", subscription_change_kind: kind),
                       :supported?, kind
    end
  end

  def test_non_callable_credential_resolver_is_rejected
    error = assert_raises(ArgumentError) { RecordingStudioBilling::StripeAdapter.new(credential_resolver: :invalid) }

    assert_equal "stripe credential resolver must respond to call", error.message
  end

  def test_portal_session_requires_a_configured_return_origin_and_keeps_only_a_transient_stripe_url
    captured_session = nil
    captured_configuration = nil
    sessions = Object.new
    sessions.define_singleton_method(:create) do |params, _options|
      captured_session = params
      { "url" => "https://billing.stripe.com/session/test" }
    end
    configurations = Object.new
    configurations.define_singleton_method(:create) do |params, _options|
      captured_configuration = params
      { "id" => "bpc_restricted" }
    end
    portal = Struct.new(:sessions, :configurations).new(sessions, configurations)
    client = Struct.new(:v1).new(Struct.new(:billing_portal).new(portal))
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { "sk_test" }, trusted_origins_resolver: -> { ["https://app.example.test/"] },
      client_factory: ->(_secret) { client }
    )

    assert_equal({ url: "https://billing.stripe.com/session/test" },
                 adapter.portal_session(customer_reference: "cus_123", return_url: "https://app.example.test/billing"))
    assert_equal({ "customer" => "cus_123", "return_url" => "https://app.example.test/billing",
                   "configuration" => "bpc_restricted" }, captured_session)
    assert_equal false, captured_configuration.dig("features", "subscription_cancel", "enabled")
    assert_equal false, captured_configuration.dig("features", "subscription_update", "enabled")
    assert_equal true, captured_configuration.dig("features", "payment_method_update", "enabled")
    assert_equal({}, adapter.portal_session(customer_reference: "cus_123", return_url: "https://evil.example.test/billing"))
  end

  def test_portal_session_rejects_subscription_mutation_features
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { "sk_test" }, trusted_origins_resolver: -> { ["https://app.example.test"] },
      client_factory: ->(_secret) { Object.new }
    )

    assert_equal({}, adapter.portal_session(customer_reference: "cus_123", return_url: "https://app.example.test/billing",
                                            features: ["subscription_cancel"]))
  end

  def test_portal_origins_are_provider_hosts_not_host_return_origins
    adapter = RecordingStudioBilling::StripeAdapter.new(
      trusted_origins_resolver: -> { ["https://app.example.test"] }
    )

    assert_includes adapter.trusted_portal_origins, "https://billing.stripe.com"
    refute_includes adapter.trusted_portal_origins, "https://app.example.test"
  end

  def test_invoice_download_rejects_a_non_stripe_pdf_url_before_fetching_it
    invoices = Object.new
    invoices.define_singleton_method(:retrieve) { |_reference| { "invoice_pdf" => "https://evil.example.test/invoice.pdf" } }
    client = Struct.new(:v1).new(Struct.new(:invoices).new(invoices))
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { "sk_test" }, client_factory: ->(_secret) { client }
    )

    assert_nil adapter.invoice_download(invoice: Object.new, provider_reference: "in_123")
  end

  def test_stripe_tax_maps_semantic_categories_and_normalizes_minor_unit_response
    captured = nil
    calculations = Object.new
    calculations.define_singleton_method(:create) do |params, options|
      captured = { params:, options: }
      { "id" => "taxcalc_123", "created" => 1_700_000_000, "tax_amount_exclusive" => 125,
        "amount_total" => 1_125, "tax_breakdown" => [{ "amount" => 125 }] }
    end
    client = Struct.new(:v1).new(Struct.new(:tax).new(Struct.new(:calculations).new(calculations)))
    calculator = RecordingStudioBilling::StripeAdapter::TaxCalculator.new(
      credential_resolver: -> { "sk_test" }, tax_code_resolver: ->(category) { "txcd_#{category}" },
      client_factory: ->(_secret) { client }
    )
    request = {
      "request" => {
        "currency" => "USD", "subtotal_minor" => 1_000, "discount_minor" => 0, "behavior" => "exclusive",
        "verified_location" => { "country" => "US", "region" => "CA" },
        "lines" => [{ "reference" => "line_1", "amount_minor" => 1_000, "tax_category" => "digital_goods" }]
      }
    }

    response = calculator.call(command: Object.new, request:, idempotency_key: "tax-key")

    assert_equal 125, response.tax_minor
    assert_equal 1_125, response.total_minor
    assert_equal "stripe_tax", response.metadata.fetch("calculator")
    assert_equal "txcd_digital_goods", captured.fetch(:params).fetch("line_items").first.fetch("tax_code")
    assert_equal "CA", captured.fetch(:params).dig("customer_details", "address", "state")
    assert_equal "tax-key", captured.fetch(:options).fetch(:idempotency_key)
  end
end
