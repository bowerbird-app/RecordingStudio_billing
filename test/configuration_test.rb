# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    @configuration = GemTemplate::Configuration.new
  end

  def test_merge_updates_known_attributes
    @configuration.merge!(api_key: "abc123", timeout: 9, enable_feature_x: true)

    assert_equal "abc123", @configuration.api_key
    assert_equal 9, @configuration.timeout
    assert_equal true, @configuration.enable_feature_x
  end

  def test_merge_ignores_unknown_keys
    @configuration.merge!(unknown_key: "ignored", timeout: 7)

    refute_respond_to @configuration, :unknown_key
    assert_equal 7, @configuration.timeout
  end

  def test_merge_with_non_enumerable_is_noop
    original = @configuration.to_h

    @configuration.merge!(nil)

    assert_nil @configuration.api_key if original[:api_key].nil?
    assert_equal original[:api_key], @configuration.api_key unless original[:api_key].nil?
    assert_equal original[:timeout], @configuration.timeout
    assert_equal original[:enable_feature_x], @configuration.enable_feature_x
  end

  def test_initialize_uses_environment_api_key_and_defaults
    previous_value = ENV.fetch("GEM_TEMPLATE_API_KEY", nil)
    ENV["GEM_TEMPLATE_API_KEY"] = "env-token"

    configuration = GemTemplate::Configuration.new

    assert_equal "env-token", configuration.api_key
    assert_equal false, configuration.enable_feature_x
    assert_equal 5, configuration.timeout
    assert_instance_of GemTemplate::Hooks, configuration.hooks
  ensure
    ENV["GEM_TEMPLATE_API_KEY"] = previous_value
  end

  def test_merge_accepts_string_keys
    @configuration.merge!("api_key" => "string-key", "timeout" => 12)

    assert_equal "string-key", @configuration.api_key
    assert_equal 12, @configuration.timeout
  end

  def test_to_h_reports_registered_hook_counts
    @configuration.hooks.before_initialize { nil }
    @configuration.hooks.before_initialize { nil }
    @configuration.hooks.after_service { nil }

    result = @configuration.to_h

    assert_equal 2, result.fetch(:hooks_registered).fetch(:before_initialize)
    assert_equal 1, result.fetch(:hooks_registered).fetch(:after_service)
  end

  def test_configure_without_block_is_safe
    GemTemplate.configure

    assert_kind_of GemTemplate::Configuration, GemTemplate.configuration
  end
end
