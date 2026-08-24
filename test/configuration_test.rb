# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  class GenericAdapter
    def capabilities
      @capabilities ||= RecordingStudioBilling::ProviderCapabilities.new
    end

    def call(**)
      RecordingStudioBilling::AdapterResponse.new(status: "unsupported")
    end
  end

  def setup
    @configuration = RecordingStudioBilling::Configuration.new
  end

  def test_defaults_to_the_built_in_stripe_provider
    assert_equal :stripe, @configuration.provider
    assert_instance_of RecordingStudioBilling::StripeAdapter, @configuration.provider_registry.fetch(:stripe)
  end

  def test_merge_accepts_a_provider_override
    @configuration.merge!("provider" => "test_provider")

    assert_equal :test_provider, @configuration.provider
  end

  def test_host_can_select_a_custom_adapter_without_replacing_stripe
    adapter = GenericAdapter.new

    @configuration.provider_registry.register(:alternate, adapter)
    @configuration.provider = :alternate

    assert_equal :alternate, @configuration.provider
    assert_same adapter, @configuration.provider_registry.fetch(:alternate)
    assert_instance_of RecordingStudioBilling::StripeAdapter, @configuration.provider_registry.fetch(:stripe)
  end

  def test_accepts_a_stripe_credential_resolver
    resolver = -> {}

    @configuration.stripe_credential_resolver = resolver

    assert_same resolver, @configuration.stripe_credential_resolver
  end

  def test_normalizes_stripe_trusted_origins_and_registers_the_opt_in_tax_calculator
    @configuration.stripe_trusted_origins = ["https://app.example.test/", "https://app.example.test"]

    assert_equal ["https://app.example.test"], @configuration.stripe_trusted_origins
    assert_instance_of RecordingStudioBilling::StripeAdapter::TaxCalculator,
                       @configuration.tax_calculator_registry.fetch(:stripe_tax)
  end

  def test_rejects_a_blank_provider
    error = assert_raises(ArgumentError) { @configuration.provider = "  " }

    assert_equal "provider must be present", error.message
  end

  def test_merge_rejects_unknown_keys
    error = assert_raises(ArgumentError) { @configuration.merge!(unknown_key: "ignored") }

    assert_equal "unsupported commercial configuration key: unknown_key", error.message
  end

  def test_authorizer_must_be_callable
    error = assert_raises(ArgumentError) { @configuration.commercial_authorizer = :not_callable }

    assert_equal "commercial_authorizer must respond to call", error.message
  end

  def test_normalizes_product_display_names
    @configuration.product_display_names = { demo_monthly_plan: "Pro" }

    assert_equal "Pro", @configuration.product_display_names.fetch("demo_monthly_plan")
  end

  def test_merge_accepts_customer_delivery_copy_and_support_link
    @configuration.merge!(
      billing_copy: { settings_notice: "Contact billing support." },
      support_url: "https://support.example.test/billing"
    )

    assert_equal "Contact billing support.", @configuration.billing_copy.fetch("settings_notice")
    assert_equal "https://support.example.test/billing", @configuration.support_url
  end
end
