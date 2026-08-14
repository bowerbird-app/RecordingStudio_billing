# frozen_string_literal: true

module RecordingStudioBilling
  class ProviderCapabilities
    DIMENSIONS = %i[
      operations currencies markets collection_methods checkout_modes tax_modes
      quantities composition refunds adjustments subscription_change_kinds
      usage_settlement_representations
    ].freeze

    Evaluation = Data.define(:supported, :reason, :explanation, :constraints) do
      def supported?
        supported
      end
    end

    attr_reader :constraints

    def initialize(**values)
      unknown = values.keys - (DIMENSIONS + [:constraints])
      raise ArgumentError, "unknown capability dimensions: #{unknown.join(', ')}" if unknown.any?

      @values = DIMENSIONS.to_h { |dimension| [dimension, normalize(values.fetch(dimension, []))] }.freeze
      @constraints = SafeFinancialPayload.normalize(values.fetch(:constraints, {})).freeze
    end

    def evaluate(**requirements)
      requirements = requirements.to_h do |dimension, value|
        normalized_dimension = DIMENSIONS.include?(dimension) ? dimension : dimension.to_s.pluralize.to_sym
        [normalized_dimension, value]
      end
      unknown = requirements.keys - DIMENSIONS
      raise ArgumentError, "unknown capability requirements: #{unknown.join(', ')}" if unknown.any?

      requirements.each do |dimension, requested|
        requested_values = normalize(requested)
        next if requested_values.all? { |value| @values.fetch(dimension).include?(value) }

        return Evaluation.new(
          supported: false,
          reason: "unsupported_#{dimension.to_s.singularize}",
          explanation: "The provider does not support the requested #{dimension.to_s.tr('_', ' ')}.",
          constraints:
        )
      end

      Evaluation.new(
        supported: true,
        reason: "supported",
        explanation: "The provider supports the requested operation.",
        constraints:
      )
    end

    def to_h
      @values.merge(constraints:).transform_values { |value| value.is_a?(Array) ? value.dup : value }
    end

    def evaluate_any(dimension:, values:)
      dimension = dimension.to_sym
      raise ArgumentError, "unknown capability dimension: #{dimension}" unless DIMENSIONS.include?(dimension)

      supported = normalize(values).find { |value| @values.fetch(dimension).include?(value) }
      return Evaluation.new(supported: true, reason: "supported", explanation: "The provider supports the requested operation.", constraints:) if supported

      Evaluation.new(
        supported: false,
        reason: "unsupported_#{dimension.to_s.singularize}",
        explanation: "The provider does not support a safe #{dimension.to_s.tr('_', ' ')}.",
        constraints:
      )
    end

    private

    def normalize(value)
      Array(value).map { |item| item.to_s.strip.downcase }.reject(&:empty?).uniq.sort.freeze
    end
  end
end
