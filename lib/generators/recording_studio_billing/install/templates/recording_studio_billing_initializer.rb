# frozen_string_literal: true

RecordingStudioBilling.configure do |config|
  # Stripe is the default adapter. Override this symbol when adding a provider adapter.
  config.provider = :stripe
end
