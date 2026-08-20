# frozen_string_literal: true

namespace :stripe do
  desc "Open and expire a $1 Stripe test Checkout session using dummy host secrets"
  task ping: :environment do
    abort "Stripe test credentials are not configured" unless DummyStripeTestCredentials.present?

    adapter = RecordingStudioBilling::StripeAdapter.new(
      credential_resolver: -> { DummyStripeTestCredentials.to_h },
      trusted_origins_resolver: -> { [DummyStripeTestCredentials::RETURN_ORIGIN] }
    )
    command = Struct.new(:command_type, :operation_id).new("checkout", "dummy-stripe-ping-#{SecureRandom.uuid}")
    response = adapter.call(
      command:,
      request: DummyStripeTestCredentials.checkout_probe_request,
      idempotency_key: "dummy-stripe-ping-#{SecureRandom.uuid}"
    )
    abort "Stripe test ping failed: #{response.status} #{response.result}" unless response.status == "pending"

    Stripe::StripeClient.new(DummyStripeTestCredentials.secret_key).v1.checkout.sessions.expire(
      response.provider_reference
    )
    puts "Stripe test account accepted checkout session #{response.provider_reference}"
  end
end
