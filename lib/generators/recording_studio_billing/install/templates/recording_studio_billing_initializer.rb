# frozen_string_literal: true

RecordingStudioBilling.configure do |config|
  # Stripe is built in and selected by default. Resolve credentials from host-managed secrets at execution time.
  # config.stripe_credential_resolver = -> { Rails.application.credentials.dig(:billing, :stripe) }
  #
  # Custom adapters use the same registry API:
  # RecordingStudioBilling.register_provider(:your_provider, YourProviderAdapter.new)
  # config.provider = :your_provider
end
