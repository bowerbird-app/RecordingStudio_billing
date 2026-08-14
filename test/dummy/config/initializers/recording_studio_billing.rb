# frozen_string_literal: true

require File.expand_path("../../../../app/services/recording_studio_billing/fake_financial_adapter", __dir__)

module RecordingStudioBilling
  class DummyFinancialAdapter < FakeFinancialAdapter
    def initialize(outcome: :success)
      super(outcome:, capabilities: ProviderCapabilities.new(
        operations: %w[charge checkout subscription subscription_change refund adjustment tax],
        currencies: %w[EUR GBP USD], markets: %w[DE GB IT US], collection_methods: %w[automatic],
        checkout_modes: %w[payment redirect subscription], tax_modes: %w[external provider], quantities: %w[fixed adjustable],
        composition: %w[single mixed], refunds: %w[full partial], adjustments: %w[credit debit],
        subscription_change_kinds: %w[plan interval addon quantity cancellation resumption]
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

    private

    def checkout_command_response(command, status)
      intent = CheckoutIntent.find_by!(financial_command: command)
      AdapterResponse.new(status:, provider_reference: "dummy-checkout-#{intent.id}",
                          result: { "checkout_intent_id" => intent.id }, metadata: { "adapter" => "dummy" })
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
  config.billing_location_context_resolver = lambda do |**|
    { host_country: RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("US", :host) }
  end
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
      source: "catalogue", merge_rule: "replace", default: true, type: "boolean", meter_key: "demo_api_calls",
      usage_unit_key: "demo_api_call", replenishment: "none", lifecycle: "purchase", consumption: "metered", ordering: 2,
      validation: {}
    }
  }
end
