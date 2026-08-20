# frozen_string_literal: true

require "test_helper"

class StripeTestAccountIntegrationTest < ActiveSupport::TestCase
  setup do
    skip "Stripe test credentials are not configured" unless DummyStripeTestCredentials.present?
  end

  test "the Stripe adapter can open and expire a Checkout session on the test account" do
    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { DummyStripeTestCredentials.to_h },
      trusted_origins_resolver: -> { [ DummyStripeTestCredentials::RETURN_ORIGIN ] }
    )
    command = Struct.new(:command_type, :operation_id).new("checkout", "live-probe-#{SecureRandom.uuid}")

    response = adapter.call(
      command:,
      request: DummyStripeTestCredentials.checkout_probe_request,
      idempotency_key: "live-probe-#{SecureRandom.uuid}"
    )

    assert_equal "pending", response.status, response.result.inspect
    assert_match(/\Acs_test_/, response.provider_reference)

    Stripe::StripeClient.new(DummyStripeTestCredentials.secret_key).v1.checkout.sessions.expire(
      response.provider_reference
    )
  end
end
