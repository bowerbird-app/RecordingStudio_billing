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
    @configuration.billing_provider_component(:primary, :checkout, component)
    @configuration.billing_copy = { checkout_pending: "Awaiting confirmation." }
    @configuration.support_url = "https://support.example.test/billing"

    assert_equal "RecordingStudioBilling::StripeCheckoutComponent",
                 @configuration.billing_provider_component(:stripe, :checkout)
    assert_equal component, @configuration.billing_provider_component(:primary, :checkout)
    assert_nil @configuration.billing_provider_component(:other, :checkout)
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

  def test_customer_components_render_named_extension_slots
    presenter = RecordingStudioBilling::AddonsPresenter.new(
      root_recording: Struct.new(:id).new("root-1"), purchases: [], eligible_options: []
    )
    component = RecordingStudioBilling::AddonsComponent.new(presenter:)
    component.with_header_extension { "Header extension" }
    component.with_body_extension { "Body extension" }
    component.with_footer_extension { "Footer extension" }

    html = RecordingStudioBilling::ApplicationController.render(
      inline: "<%= render component %>", locals: { component: }
    )

    assert_includes html, "Header extension"
    assert_includes html, "Body extension"
    assert_includes html, "Footer extension"
  end

  def test_non_stripe_embedded_presentation_renders_generic_fallback_without_stripe_browser_code
    command = Struct.new(:provider_adapter_key).new("primary")
    intent = Struct.new(:state, :financial_command).new("awaiting_confirmation", command)
    presenter = CheckoutRenderingPresenter.new(intent)

    html = RecordingStudioBilling::ApplicationController.render(
      inline: '<%= render template: "recording_studio_billing/checkout/show" %>', assigns: { presenter: }
    )

    refute_includes html, "data-stripe-checkout-client-secret"
    refute_includes html, "data-stripe-publishable-key"
    refute_includes html, "https://js.stripe.com/v3/"
    refute_includes html, "recording_studio_billing/stripe_checkout"
    assert_includes html, "Your payment is being prepared or is awaiting provider confirmation."
  end

  def test_checkout_component_renders_plan_price_and_tax_at_checkout_without_authoritative_completion_claim
    line = Struct.new(:commercial_manifest).new({
                                                  "canonical_data" => {
                                                    "product" => { "name" => "Studio Pro" },
                                                    "billing_option" => { "recurrence" => "recurring", "interval" => "month" },
                                                    "price" => { "amount_minor" => 1_000, "currency_code" => "EUR" },
                                                    "tax" => { "status" => "estimated" }, "benefits" => { "minutes" => 120 },
                                                    "overage" => { "policy" => "metered" }, "market" => { "country_code" => "IT" }
                                                  }
                                                })
    line.define_singleton_method(:quantity) { 3 }
    intent = Struct.new(:items, :state, :financial_command).new([line], "awaiting_confirmation", nil)
    presenter = RecordingStudioBilling::CheckoutPresenter.new(root_recording: Struct.new(:id).new("root-1"),
                                                              checkout_intent: intent, presentation: {})

    html = RecordingStudioBilling::ApplicationController.render(
      inline: "<%= render RecordingStudioBilling::CheckoutComponent.new(presenter: presenter) %>", locals: { presenter: }
    )

    assert_includes html, "Studio Pro"
    assert_includes html, "3 x 1000 EUR"
    assert_includes html, "monthly"
    assert_includes html, "Tax is calculated at checkout"
    refute_includes html, "Overage policy"
    refute_includes html, "Market:"
    refute_includes html, "Benefits:"
    assert_includes html, "Browser completion does not confirm a purchase."
  end

  class CheckoutRenderingPresenter
    attr_reader :checkout_intent, :presentation

    def initialize(checkout_intent)
      @checkout_intent = checkout_intent
      @presentation = { mode: "embedded", client_secret: "non_stripe_client_secret", publishable_key: "non_stripe_public_key" }
    end

    def embedded? = true

    def redirect? = false

    def frozen_lines = []

    def copy(_key, default) = default

    def page_contents(_page) = []
  end
end
