# frozen_string_literal: true

module RecordingStudioBilling
  class CalculateOverage
    def self.call(...) = new(...).call

    def initialize(allocation:, rate:)
      @allocation = allocation
      @rate = rate
    end

    def call
      OverageCalculation.find_or_create_by!(usage_allocation: allocation) do |calculation|
        amount = Integer(rate.fetch("amount_minor"))
        package_size = Integer(rate.fetch("package_size", 1) || 1)
        raise ArgumentError, "overage package size must be positive" unless package_size.positive?

        calculation.excess_quantity = allocation.excess_quantity
        numerator = allocation.excess_quantity * amount
        calculation.amount_minor = (numerator + package_size - 1) / package_size
        calculation.currency_code = rate.fetch("currency_code")
        calculation.currency_exponent = Integer(rate.fetch("currency_exponent"))
        calculation.rate_snapshot = SafeFinancialPayload.normalize(rate, allow_authoritative_totals: true)
      end
    end

    private

    attr_reader :allocation, :rate
  end
end
