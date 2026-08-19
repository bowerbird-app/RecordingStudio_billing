# frozen_string_literal: true

RecordingStudioBilling.configure do |config|
  # Stripe is built in and selected by default. Resolve credentials from host-managed secrets at execution time.
  # config.stripe_credential_resolver = -> { Rails.application.credentials.dig(:billing, :stripe) }
  #
  # Custom adapters use the same registry API:
  # RecordingStudioBilling.register_provider(:your_provider, YourProviderAdapter.new)
  # config.provider = :your_provider
  #
  # The install generator adds `draw_recording_studio_billing_plans` to routes.rb.
  # Change the path in routes.rb if you want a different URL than /plans.
  config.plans_page_route_helper = :plans_path
  config.plans_page_requires_sign_in = true
end
