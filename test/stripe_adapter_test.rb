# frozen_string_literal: true

require "test_helper"

class StripeAdapterTest < Minitest::Test
  def test_capabilities_use_the_shared_generic_contract
    adapter = RecordingStudioBilling::StripeAdapter.new
    evaluation = adapter.capabilities.evaluate(operation: :charge)

    assert_instance_of RecordingStudioBilling::ProviderCapabilities, adapter.capabilities
    refute evaluation.supported?
    assert_equal "unsupported_operation", evaluation.reason
  end

  def test_absent_credentials_return_a_normalized_unavailable_response_without_resolving_a_client
    resolver_calls = 0
    adapter = RecordingStudioBilling::StripeAdapter.new(credential_resolver: -> { resolver_calls += 1; nil })

    response = adapter.call(command: Object.new, request: {}, idempotency_key: "test-key")

    assert_equal 1, resolver_calls
    assert_equal "provider_unavailable", response.status
    assert_equal "configuration_missing", response.result.fetch("reason")
    assert_equal({ "adapter" => "stripe" }, response.metadata)
  end

  def test_configured_credentials_are_resolved_only_at_execution_and_never_persisted
    credential = "test-stripe-credential"
    resolver_calls = 0
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { resolver_calls += 1; credential }
    )

    assert_equal 0, resolver_calls
    response = adapter.call(command: Object.new, request: {}, idempotency_key: "test-key")

    assert_equal 1, resolver_calls
    assert_equal "unsupported", response.status
    assert_equal "operation_not_implemented", response.result.fetch("reason")
    refute defined?(Stripe)
    refute_includes [response.result, response.error_details, response.metadata].to_s, credential
  end

  def test_non_callable_credential_resolver_is_rejected
    error = assert_raises(ArgumentError) { RecordingStudioBilling::StripeAdapter.new(credential_resolver: :invalid) }

    assert_equal "stripe credential resolver must respond to call", error.message
  end
end