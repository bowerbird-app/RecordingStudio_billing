# frozen_string_literal: true

module RecordingStudioBilling
  class TaxResponse < AdapterResponse
    attr_reader :subtotal_minor, :discount_minor, :tax_minor, :total_minor, :currency, :behavior,
                :breakdown, :calculator_reference, :calculated_at, :request_fingerprint

    def initialize(status:, subtotal_minor:, discount_minor:, tax_minor:, total_minor:, currency:, behavior:,
                   calculator_reference:, calculated_at:, request_fingerprint:, breakdown: [], metadata: {})
      @subtotal_minor = integer!(subtotal_minor)
      @discount_minor = integer!(discount_minor)
      @tax_minor = integer!(tax_minor)
      @total_minor = integer!(total_minor)
      @currency = currency.to_s.upcase
      @behavior = behavior.to_s
      @breakdown = normalize_breakdown(breakdown)
      @calculator_reference = calculator_reference.to_s
      SafeFinancialPayload.normalize_reference(@calculator_reference, label: "calculator reference")
      @calculated_at = calculated_at.in_time_zone
      @request_fingerprint = request_fingerprint.to_s
      validate_arithmetic!
      super(status:, result: result_payload, metadata:, allow_authoritative_totals: true)
    end

    private

    def result_payload
      {
        "subtotal_minor" => subtotal_minor, "discount_minor" => discount_minor, "tax_minor" => tax_minor,
        "total_minor" => total_minor, "currency" => currency, "behavior" => behavior,
        "breakdown" => breakdown, "calculator_reference" => calculator_reference,
        "calculated_at" => calculated_at.iso8601(6), "request_fingerprint" => request_fingerprint
      }
    end

    def validate_arithmetic!
      raise ArgumentError, "tax currency is invalid" unless currency.match?(/\A[A-Z]{3}\z/)
      raise ArgumentError, "tax behavior is invalid" unless TaxCalculatorCapabilities::BEHAVIORS.include?(behavior)
      raise ArgumentError, "tax monetary values cannot be negative" if [subtotal_minor, discount_minor, tax_minor, total_minor].any?(&:negative?)
      expected = subtotal_minor - discount_minor
      expected += tax_minor if behavior == "exclusive"
      raise ArgumentError, "tax arithmetic is inconsistent" unless total_minor == expected
      raise ArgumentError, "inclusive tax exceeds total" if behavior == "inclusive" && tax_minor > total_minor
    end

    def normalize_breakdown(value)
      Array(value).map do |entry|
        data = entry.respond_to?(:to_h) ? entry.to_h : {}
        raise ArgumentError, "tax breakdown amounts must use integer minor units" unless data.values_at(:amount_minor, "amount_minor").compact.all?(Integer)

        SafeFinancialPayload.normalize(data)
      end.freeze
    end

    def integer!(value)
      raise ArgumentError, "tax values must use integer minor units" unless value.is_a?(Integer)

      value
    end
  end
end