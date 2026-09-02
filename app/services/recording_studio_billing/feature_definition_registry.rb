# frozen_string_literal: true

# rubocop:disable Lint/MissingCopEnableDirective

module RecordingStudioBilling
  class FeatureDefinitionRegistry
    MERGE_RULES = %w[replace merge append minimum maximum].freeze
    TYPES = Feature::TYPES.freeze

    class << self
      def fetch!(key)
        configuration.fetch(key.to_s) { raise KeyError, "unknown feature definition: #{key}" }
      end

      def normalize(value)
        definition = value.respond_to?(:to_h) ? value.to_h.transform_keys(&:to_sym) : {}
        required = %i[source merge_rule default type]
        missing = required.reject { |key| definition.key?(key) }
        raise ArgumentError, "feature definition is missing: #{missing.join(', ')}" if missing.any?

        type = definition[:type].to_s
        merge_rule = definition[:merge_rule].to_s
        raise ArgumentError, "unsupported feature type" unless TYPES.include?(type)
        raise ArgumentError, "unsupported feature merge rule" unless MERGE_RULES.include?(merge_rule)

        normalized = definition.slice(
          :source, :merge_rule, :default, :type, :meter_key, :usage_unit_key,
          :replenishment, :lifecycle, :consumption, :ordering, :validation
        ).transform_keys(&:to_s)
        normalized["type"] = type
        normalized["merge_rule"] = merge_rule
        normalized["meter_key"] = normalized["meter_key"].presence&.to_s
        normalized["usage_unit_key"] = normalized["usage_unit_key"].presence&.to_s
        normalized
      end

      private

      def configuration
        RecordingStudioBilling.configuration.feature_definitions
      end
    end
  end
end
