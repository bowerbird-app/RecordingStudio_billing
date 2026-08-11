# frozen_string_literal: true

module RecordingStudioBilling
  class FakeTaxCalculator
    OUTCOMES = %i[
      exclusive inclusive provider_calculated pending invalid provider_unavailable
      mismatched_subtotal mismatched_total mismatched_currency unknown
    ].freeze

    attr_reader :capabilities, :calls, :idempotency_keys

    def initialize(outcome:, capabilities: nil, clock: -> { Time.current })
      @outcomes = Array(outcome).map(&:to_sym)
      raise ArgumentError, "unsupported fake tax outcome" unless @outcomes.present? && (@outcomes - OUTCOMES).empty?

      @capabilities = capabilities || TaxCalculatorCapabilities.new(
        mode: @outcomes.include?(:provider_calculated) ? :provider_calculation : :external_calculation,
        transactions: %w[sale refund], currencies: %w[USD EUR], markets: %w[US GB],
        behaviors: %w[inclusive exclusive provider_default], location: true,
        classification: true, tax_id: false, breakdown: true
      )
      @calls = 0
      @idempotency_keys = []
      @clock = clock
    end

    def validate!(request:)
      raise ArgumentError, "fake tax request is invalid" if current_outcome == :invalid
      raise ArgumentError, "tax request must be an object" unless request.is_a?(Hash)
    end

    def call(command:, request:, idempotency_key:)
      outcome = current_outcome
      @calls += 1
      @idempotency_keys << idempotency_key
      raise ArgumentError, "calculator received a noncanonical request" unless request == command.canonical_request

      payload = request.fetch("request")
      status = { pending: "pending", provider_unavailable: "provider_unavailable", unknown: "provider_state" }
           .fetch(outcome, "success")
      behavior = { inclusive: "inclusive", exclusive: "exclusive" }.fetch(outcome, payload.fetch("behavior"))
      tax = 100
      subtotal = payload.fetch("subtotal_minor") + (outcome == :mismatched_subtotal ? 1 : 0)
      currency = outcome == :mismatched_currency ? "EUR" : payload.fetch("currency")
      total = subtotal - payload.fetch("discount_minor")
      total += tax if behavior == "exclusive"
      total += 1 if outcome == :mismatched_total
      TaxResponse.new(
        status:, subtotal_minor: subtotal, discount_minor: payload.fetch("discount_minor"),
        tax_minor: tax, total_minor: total, currency:, behavior:,
        calculator_reference: "fake-calculation", calculated_at: @clock.call,
        request_fingerprint: CommercialManifestCanonicalizer.digest(payload),
        breakdown: [{ "category" => "standard", "amount_minor" => tax }],
        metadata: { "calculator" => "fake", "authoritative" => outcome == :provider_calculated }
      )
    end

    private

    def current_outcome
      @outcomes.fetch([calls, @outcomes.length - 1].min)
    end
  end
end