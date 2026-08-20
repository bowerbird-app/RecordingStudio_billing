# frozen_string_literal: true

# Reads Stripe *test* keys from the dummy host environment. Cursor Cloud secrets
# keep the lowercase names `stripe_test_secret_key` and
# `stripe_test_publishable_key`. Local shells may use the uppercase aliases.
# Live `sk_live` / `pk_live` values are ignored.
module DummyStripeTestCredentials
  RETURN_ORIGIN = "https://example.com"
  SECRET_ENV_NAMES = %w[stripe_test_secret_key STRIPE_TEST_SECRET_KEY STRIPE_SECRET_KEY].freeze
  PUBLISHABLE_ENV_NAMES = %w[stripe_test_publishable_key STRIPE_TEST_PUBLISHABLE_KEY STRIPE_PUBLISHABLE_KEY].freeze

  module_function

  def secret_key
    value = first_present(SECRET_ENV_NAMES)
    value if value&.start_with?("sk_test")
  end

  def publishable_key
    value = first_present(PUBLISHABLE_ENV_NAMES)
    value if value&.start_with?("pk_test")
  end

  def present?
    secret_key.present?
  end

  def to_h
    return unless present?

    {
      secret_key:,
      publishable_key:,
      return_url: "#{RETURN_ORIGIN}/billing",
      success_url: "#{RETURN_ORIGIN}/billing",
      cancel_url: "#{RETURN_ORIGIN}/billing"
    }.compact
  end

  def checkout_probe_request
    {
      "request" => {
        "presentation" => "redirect",
        "currency" => "USD",
        "collection_method" => "automatic",
        "checkout_items" => {
          "item-1" => {
            "amount_minor" => 100,
            "quantity" => 1,
            "recurrence" => "one_time",
            "checkout_intent_item_id" => "dummy-stripe-probe",
            "manifest_digest" => "dummy-stripe-probe"
          }
        }
      }
    }
  end

  def first_present(names)
    names.map { |name| ENV[name].to_s.strip }.find(&:present?)
  end
end
