# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    @configuration = RecordingStudioBilling::Configuration.new
  end

  def test_defaults_to_stripe
    assert_equal :stripe, @configuration.provider
  end

  def test_merge_accepts_a_provider_override
    @configuration.merge!("provider" => "test_provider")

    assert_equal :test_provider, @configuration.provider
  end

  def test_rejects_a_blank_provider
    error = assert_raises(ArgumentError) { @configuration.provider = "  " }

    assert_equal "provider must be present", error.message
  end

  def test_merge_ignores_unknown_keys
    @configuration.merge!(unknown_key: "ignored")

    assert_equal :stripe, @configuration.provider
  end
end
