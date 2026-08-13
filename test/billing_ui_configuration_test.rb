# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class BillingUiConfigurationTest < Minitest::Test
  def setup
    @configuration = RecordingStudioBilling::Configuration.new
  end

  def test_presenter_overrides_can_replace_a_default_presenter
    @configuration.billing_presenter_override(:overview, RecordingStudioBilling::UsagePresenter)

    assert_equal RecordingStudioBilling::UsagePresenter,
                 @configuration.billing_presenter_for(:overview, RecordingStudioBilling::OverviewPresenter)
  end

  def test_navigation_and_page_content_hooks_run_in_priority_order
    @configuration.hooks.billing_navigation(priority: 200) { { label: "Later" } }
    @configuration.hooks.billing_navigation(priority: 100) { { label: "First" } }
    @configuration.hooks.billing_page_content(:usage) { "Usage extension" }
    presenter = RecordingStudioBilling::UsagePresenter.new(root_recording: Object.new, entitlements: {})

    assert_equal %w[First Later], @configuration.hooks.billing_navigation_items(presenter).pluck(:label)
    assert_equal ["Usage extension"], @configuration.hooks.billing_page_contents(:usage, presenter)
  end

  def test_provider_component_and_copy_support_contracts_are_available
    component = Class.new
    @configuration.billing_provider_component(:checkout, component)
    @configuration.billing_copy = { checkout_pending: "Awaiting confirmation." }
    @configuration.support_url = "https://support.example.test/billing"

    assert_equal component, @configuration.billing_provider_component(:checkout)
    assert_equal "Awaiting confirmation.", @configuration.billing_copy.fetch("checkout_pending")
    assert_equal "https://support.example.test/billing", @configuration.support_url
  end

  def test_location_context_resolver_is_available_for_customer_offer_display
    resolver = ->(**) { { host_country: "DE" } }

    @configuration.billing_location_context_resolver = resolver

    assert_same resolver, @configuration.billing_location_context_resolver
    assert_equal "DE", @configuration.billing_location_context_resolver.call.fetch(:host_country)
  end

  def test_usage_component_renders_presenter_data_through_the_engine_controller
    root = Struct.new(:id).new("root-1")
    presenter = RecordingStudioBilling::UsagePresenter.new(
      root_recording: root,
      entitlements: { "credits" => { "minutes" => 12 } }
    )

    html = RecordingStudioBilling::ApplicationController.render(
      inline: "<%= render RecordingStudioBilling::UsageComponent.new(presenter: presenter) %>",
      locals: { presenter: }
    )

    assert_includes html, "Usage &amp; Credits"
    assert_includes html, "minutes"
  end
end
