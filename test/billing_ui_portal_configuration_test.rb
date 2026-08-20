# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class BillingUiPortalConfigurationTest < Minitest::Test
  def test_portal_context_resolver_accepts_provider_neutral_context
    configuration = RecordingStudioBilling::Configuration.new
    resolver = ->(**) { { adapter_key: :test_provider, customer_reference: "customer-1", options: {} } }

    configuration.billing_portal_context_resolver = resolver

    assert_same resolver, configuration.billing_portal_context_resolver
    assert_equal :test_provider, configuration.billing_portal_context_resolver.call.fetch(:adapter_key)
  end

  def test_portal_context_resolver_requires_a_callable
    configuration = RecordingStudioBilling::Configuration.new

    assert_raises(ArgumentError) { configuration.billing_portal_context_resolver = "test_provider" }
  end
end
