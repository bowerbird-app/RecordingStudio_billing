# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class BillingUiDisplayMarketResolverTest < Minitest::Test
  def setup
    @configuration = RecordingStudioBilling.configuration
    @default_country = @configuration.market_default_country
    @configuration.market_default_country = "DE"
  end

  def teardown
    @configuration.market_default_country = @default_country
  end

  def test_display_resolution_passes_the_full_advisory_precedence_to_market_resolver
    captured = nil
    resolver = Object.new
    resolved = resolution(:market, "EUR", "IT", :verified_account)
    resolver.define_singleton_method(:resolve) do |**arguments|
      captured = arguments
      resolved
    end

    with_markets([]) do
      RecordingStudio.stub(:root_recording_or_self, root) do
        RecordingStudioBilling::MarketResolver.stub(:new, resolver) do
          result = RecordingStudioBilling::DisplayMarketResolver.call(
            product: product, root_recording: root, account_recording: account_recording,
            location_context: {
              verified_account_country: "IT", provider_country: "FR", host_country: "GB",
              declaration_country: "US", ip_country: "CA", account_currency: "EUR"
            }
          )

          assert_equal "EUR", result.currency_code
        end
      end
    end

    assert_equal :display, captured.fetch(:stage)
    assert_equal "IT", captured.fetch(:account_country)
    assert_equal "FR", captured.fetch(:provider_country)
    assert_equal "GB", captured.fetch(:host_country)
    assert_equal "US", captured.fetch(:declaration_country)
    assert_equal "CA", captured.fetch(:ip_country)
    assert_equal "EUR", captured.fetch(:account_currency)
  end

  def test_configured_default_country_is_available_to_market_resolver_configuration
    resolver = Object.new
    resolved = resolution(:market, "EUR", "DE", :default)
    resolver.define_singleton_method(:resolve) { |**| resolved }
    configured = nil

    with_markets([]) do
      RecordingStudio.stub(:root_recording_or_self, root) do
        RecordingStudioBilling::MarketResolver.stub(:new, lambda { |markets:, configuration:|
          configured = configuration
          resolver
        }) do
          result = RecordingStudioBilling::DisplayMarketResolver.call(product: product, root_recording: root,
                                                                      account_recording: account_recording)

          assert_equal "DE", result.country_code
        end
      end
    end

    assert_equal "DE", configured.market_default_country
  end

  def test_ambiguous_display_market_does_not_fall_back_globally
    with_markets([]) do
      RecordingStudio.stub(:root_recording_or_self, root) do
        RecordingStudioBilling::MarketResolver.stub(:new, lambda { |**|
          Object.new.tap do |resolver|
            resolver.define_singleton_method(:resolve) do |**|
              raise ArgumentError, "ambiguous market resolution for IT"
            end
          end
        }) do
          assert_raises(ArgumentError) do
            RecordingStudioBilling::DisplayMarketResolver.call(product: product, root_recording: root,
                                                               account_recording: account_recording)
          end
        end
      end
    end
  end

  private

  def root = Struct.new(:id).new("root")

  def account_recording
    Struct.new(:recordable).new(Struct.new(:billing_country_code, :billing_currency_code).new(
                                  nil, nil
                                ))
  end

  def product = Struct.new(:provider_account_recording_id).new("provider")

  def resolution(market, currency, country, source)
    RecordingStudioBilling::MarketResolver::Resolution.new(market, currency, country, :display, source, :resolved, nil)
  end

  def with_markets(markets, &)
    relation = Object.new
    relation.define_singleton_method(:where) { |**| markets }
    RecordingStudioBilling::Market.stub(:with_current_recording, relation, &)
  end
end
