# frozen_string_literal: true

require "test_helper"

class StripeUsageSettlementTest < Minitest::Test
  def test_usage_commands_are_not_advertised_as_supported
    adapter = RecordingStudioBilling::StripeAdapter.new

    %i[usage_settlement usage_correction].each do |operation|
      evaluation = adapter.capabilities.evaluate(operation:)

      refute_predicate evaluation, :supported?
      assert_equal "unsupported_operation", evaluation.reason
    end
  end

  def test_usage_commands_are_rejected_without_a_stripe_request
    client_calls = 0
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { "sk_test" },
      client_factory: lambda { |_|
        client_calls += 1
        raise "Stripe client must not be created"
      }
    )

    %w[usage_settlement usage_correction].each do |command_type|
      command = Struct.new(:command_type).new(command_type)
      response = adapter.call(command:, request: {}, idempotency_key: "durable-key")

      assert_equal "unsupported", response.status
      assert_equal "unsupported_operation", response.result.fetch("reason")
    end
    assert_equal 0, client_calls
  end
end
