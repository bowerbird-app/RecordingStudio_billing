# frozen_string_literal: true

module RecordingStudioBilling
  class TaxCalculatorCapabilities
    MODES = %w[external_calculation provider_calculation].freeze
    BEHAVIORS = %w[inclusive exclusive provider_default].freeze

    attr_reader :mode, :constraints

    def initialize(mode:, transactions:, currencies:, markets:, behaviors:, location: false,
                   classification: false, tax_id: false, breakdown: false, constraints: {})
      @mode = mode.to_s
      raise ArgumentError, "tax calculator mode is invalid" unless MODES.include?(@mode)

      @transactions = normalize(transactions)
      @currencies = normalize(currencies, &:upcase)
      @markets = normalize(markets, &:upcase)
      @behaviors = normalize(behaviors)
      raise ArgumentError, "tax behavior is invalid" unless @behaviors.all? { |item| BEHAVIORS.include?(item) }

      @features = { location: location == true, classification: classification == true,
                    tax_id: tax_id == true, breakdown: breakdown == true }.freeze
      @constraints = SafeFinancialPayload.normalize(constraints).freeze
    end

    def evaluate(transaction:, currency:, market:, behavior:, **features)
      checks = {
        transaction: @transactions.include?(transaction.to_s.downcase),
        currency: @currencies.include?(currency.to_s.upcase),
        market: @markets.include?(market.to_s.upcase),
        tax_calculation: @behaviors.include?(behavior.to_s.downcase)
      }
      features.each { |feature, required| checks[feature] = !required || @features.fetch(feature, false) }
      failed = checks.find { |_name, supported| !supported }
      return supported_evaluation unless failed

      reason = failed.first == :tax_calculation ? "unsupported_tax_calculation" : "unsupported_#{failed.first}"
      ProviderCapabilities::Evaluation.new(
        supported: false, reason:, explanation: "The tax calculator does not support the requested #{failed.first}.",
        constraints:
      )
    end

    def to_h
      {
        mode:, transactions: @transactions.dup, currencies: @currencies.dup, markets: @markets.dup,
        behaviors: @behaviors.dup, features: @features.dup, constraints:
      }
    end

    private

    def normalize(values)
      Array(values).map { |value| block_given? ? yield(value.to_s.strip) : value.to_s.strip.downcase }
                   .reject(&:empty?).uniq.sort.freeze
    end

    def supported_evaluation
      ProviderCapabilities::Evaluation.new(
        supported: true, reason: "supported", explanation: "The tax calculator supports the request.", constraints:
      )
    end
  end
end