# frozen_string_literal: true

require "test_helper"

class DummyStripeTestCredentialsTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @previous = {
      "stripe_test_secret_key" => ENV["stripe_test_secret_key"],
      "stripe_test_publishable_key" => ENV["stripe_test_publishable_key"],
      "STRIPE_TEST_SECRET_KEY" => ENV["STRIPE_TEST_SECRET_KEY"],
      "STRIPE_TEST_PUBLISHABLE_KEY" => ENV["STRIPE_TEST_PUBLISHABLE_KEY"],
      "STRIPE_SECRET_KEY" => ENV["STRIPE_SECRET_KEY"],
      "STRIPE_PUBLISHABLE_KEY" => ENV["STRIPE_PUBLISHABLE_KEY"]
    }
    @previous.each_key { |name| ENV.delete(name) }
  end

  teardown do
    @previous.each do |name, value|
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end

  test "ignores live Stripe keys and empty values" do
    ENV["stripe_test_secret_key"] = "sk_live_not_for_dummy"
    ENV["STRIPE_SECRET_KEY"] = " "
    ENV["stripe_test_publishable_key"] = "pk_live_not_for_dummy"

    refute DummyStripeTestCredentials.present?
    assert_nil DummyStripeTestCredentials.to_h
  end

  test "reads Cursor Cloud lowercase Stripe test secret names" do
    ENV["stripe_test_secret_key"] = "sk_test_dummy_secret"
    ENV["stripe_test_publishable_key"] = "pk_test_dummy_publishable"

    assert DummyStripeTestCredentials.present?
    credentials = DummyStripeTestCredentials.to_h

    assert_equal "sk_test_dummy_secret", credentials.fetch(:secret_key)
    assert_equal "pk_test_dummy_publishable", credentials.fetch(:publishable_key)
    assert_equal "#{DummyStripeTestCredentials::RETURN_ORIGIN}/billing", credentials.fetch(:success_url)
  end

  test "the dummy test environment does not install a Stripe credential resolver" do
    assert Rails.env.test?
    assert_nil RecordingStudioBilling.configuration.stripe_credential_resolver
  end
end
