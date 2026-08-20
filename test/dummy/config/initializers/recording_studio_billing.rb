# frozen_string_literal: true

require File.expand_path("../../../../app/services/recording_studio_billing/fake_financial_adapter", __dir__)
require File.expand_path("../../../../app/services/recording_studio_billing/fake_tax_calculator", __dir__)

module RecordingStudioBilling
  class DummyFinancialAdapter < FakeFinancialAdapter
    def initialize(outcome: :success)
      super(outcome:, capabilities: V1Contract.provider_capabilities(
        operations: %w[checkout subscription_change refund adjustment],
        tax_modes: %w[external provider]
      ))
    end

    def call(command:, request:, idempotency_key:)
      response = super
      return response unless response.status.in?(%w[success duplicate])

      case command.command_type
      when "checkout"
        checkout_command_response(command, response.status)
      when "refund"
        refund_response(command, response.status)
      when "adjustment"
        adjustment_response(command, response.status)
      else
        response
      end
    end

    def portal_session(customer_reference:, return_url:, features: nil, **)
      raise ArgumentError, "customer reference is missing" if customer_reference.blank?
      raise ArgumentError, "return URL is missing" if return_url.blank?

      RecordingStudioBilling::RestrictedPortal.validate_features!(features)
      { url: "#{dummy_portal_origin}/dummy_portal", features: RecordingStudioBilling::RestrictedPortal::ALLOWED_FEATURES }
    end

    def trusted_portal_origins
      [ dummy_portal_origin ]
    end

    def retrieve(command:)
      return unless command.command_type == "checkout"

      response = checkout_response(command, "success")
      { outcome: "succeeded", payload: response.result, remote_type: "operation", remote_id: command.provider_reference }
    end

    def invoice_download(**)
      download = StripeAdapter::TrustedInvoiceDownload.new("https://files.stripe.com/dummy-invoice.pdf")
      download.define_singleton_method(:each) do |&block|
        return self unless block

        block.call("%PDF-1.4 dummy invoice\n")
        self
      end
      download
    end

    def checkout_presentation(provider_reference:)
      intent = checkout_intent_for(provider_reference)
      return no_charge_presentation if intent.nil? && provider_reference.blank?

      return {} unless intent

      dummy_checkout_presentation(intent)
    end

    private

    def dummy_portal_origin
      if Rails.env.development?
        "http://127.0.0.1:3000"
      else
        "http://www.example.com"
      end
    end

    def checkout_command_response(command, status)
      intent = CheckoutIntent.find_by!(financial_command: command)
      AdapterResponse.new(status:, provider_reference: "dummy-checkout-#{intent.id}",
                          result: { "checkout_intent_id" => intent.id, "presentation" => intent.items.first&.presentation },
                          metadata: { "adapter" => "dummy" })
    end

    def checkout_intent_for(provider_reference)
      return if provider_reference.blank?
      return CheckoutIntent.find_by(id: provider_reference.delete_prefix("dummy-checkout-")) if provider_reference.to_s.start_with?("dummy-checkout-")

      command = FinancialCommand.find_by(provider_reference:)
      command && CheckoutIntent.find_by(financial_command: command)
    end

    def dummy_checkout_presentation(intent)
      presentation = intent.items.first&.presentation.to_s
      case presentation
      when "redirect", "payment_link", "invoice"
        { mode: presentation, url: "https://checkout.example.test/#{presentation.tr('_', '-')}/#{intent.id}" }
      when "embedded", "no_charge"
        { mode: presentation }
      else
        {}
      end
    end

    def no_charge_presentation
      { mode: "no_charge" }
    end

    def checkout_response(command, status)
      intent = CheckoutIntent.find_by!(financial_command: command)
      lines = intent.items.map do |item|
        amount = item.commercial_manifest.dig("canonical_data", "price", "amount_minor") * item.quantity
        { "checkout_intent_item_id" => item.id, "manifest_digest" => item.manifest_digest,
          "currency" => item.currency_code, "quantity" => item.quantity,
          "unit_amount_minor" => item.commercial_manifest.dig("canonical_data", "price", "amount_minor"),
          "subtotal_minor" => amount, "discount_minor" => 0, "tax_minor" => 0, "total_minor" => amount }
      end
      AdapterResponse.new(status:, provider_reference: "dummy-checkout-#{intent.id}",
                          result: { "status" => status, "subtotal_minor" => lines.sum { _1.fetch("subtotal_minor") },
                                    "discount_minor" => 0, "tax_minor" => 0,
                                    "total_minor" => lines.sum { _1.fetch("total_minor") },
                                    "currency" => intent.items.first.currency_code, "payment_state" => "captured", "lines" => lines },
                          metadata: { "adapter" => "dummy" }, allow_authoritative_totals: true)
    end

    def refund_response(command, status)
      intent = RefundIntent.find_by!(financial_command: command)
      AdapterResponse.new(status:, provider_reference: "dummy-refund-#{intent.id}",
                          result: { "status" => status, "amount_minor" => intent.amount_minor,
                                    "currency" => intent.currency_code, "payment_id" => intent.payment_id,
                                    "provider_account_recording_id" => command.provider_account_recording_id,
                                    "provider_reference" => "dummy-refund-#{intent.id}" }, metadata: { "adapter" => "dummy" },
                          allow_authoritative_totals: true)
    end

    def adjustment_response(command, status)
      intent = AdjustmentIntent.find_by!(financial_command: command)
      AdapterResponse.new(status:, provider_reference: "dummy-adjustment-#{intent.id}",
                          result: { "status" => status, "kind" => intent.kind, "amount_minor" => intent.amount_minor,
                                    "currency" => intent.currency_code, "invoice_id" => intent.invoice_id,
                                    "provider_account_recording_id" => command.provider_account_recording_id,
                                    "provider_reference" => "dummy-adjustment-#{intent.id}" }, metadata: { "adapter" => "dummy" },
                          allow_authoritative_totals: true)
    end
  end
end

RecordingStudioBilling.configure do |config|
  config.provider = :fake
  config.commercial_authorizer = ->(**) { true }
  config.default_free_plan_product_key = "demo_free_plan"
  config.billing_location_context_resolver = lambda do |**|
    { host_country: RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("US", :host) }
  end
  config.billing_portal_context_resolver = lambda do |account_recording:, **|
    { adapter_key: :fake, customer_reference: account_recording.id.to_s }
  end
  config.plans_page_route_helper = :plans_path
  config.plans_page_requires_sign_in = true
end

RecordingStudioBilling.register_provider(:fake, RecordingStudioBilling::DummyFinancialAdapter.new)

Rails.application.config.to_prepare do
  RecordingStudioBilling.configuration.feature_definitions = {
    "demo_priority_support" => {
      source: "catalogue", merge_rule: "replace", default: false, type: "boolean", meter_key: nil,
      usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 1,
      validation: {}
    },
    "demo_api_calls" => {
      source: "catalogue", merge_rule: "replace", default: 5, type: "allowance", meter_key: "demo_api_calls",
      usage_unit_key: "demo_api_call", replenishment: "period", lifecycle: "subscription", consumption: "metered",
      ordering: 2, validation: { "minimum" => 0 }
    },
    "demo_projects" => {
      source: "catalogue", merge_rule: "replace", default: 0, type: "limit", meter_key: nil,
      usage_unit_key: nil, replenishment: "none", lifecycle: "subscription", consumption: "none", ordering: 3,
      validation: { "minimum" => 0 }
    }
  }

  RecordingStudioBilling.register_gate(
    "demo_projects",
    kind: :limit,
    label: "Projects",
    count: ->(root:) { DemoUsageCounter.project_count(root) }
  )
  RecordingStudioBilling.validate_gate_configuration!

  registry = RecordingStudioBilling.configuration.tax_calculator_registry
  unless registry.keys.include?("dummy_exclusive")
    RecordingStudioBilling.register_tax_calculator(
      :dummy_exclusive, RecordingStudioBilling::FakeTaxCalculator.new(outcome: :exclusive)
    )
  end
  unless registry.keys.include?("dummy_inclusive")
    RecordingStudioBilling.register_tax_calculator(
      :dummy_inclusive, RecordingStudioBilling::FakeTaxCalculator.new(outcome: :inclusive)
    )
  end
end
