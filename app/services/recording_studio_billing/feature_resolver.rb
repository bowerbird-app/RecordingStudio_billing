# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Lint/MissingCopEnableDirective

module RecordingStudioBilling
  class FeatureResolver
    def initialize(product:, billing_option:, price:, allow_unpublished: false)
      @product = product
      @billing_option = billing_option
      @price = price
      @allow_unpublished = allow_unpublished
    end

    def resolve!
      product_features.each_with_object({}) do |feature, resolved|
        feature_key = feature.definition.fetch("_commercial_source_key", feature.key)
        definition = FeatureDefinitionRegistry.fetch!(feature_key)
        value = definition.fetch("default")
        [product.feature_values, billing_option.feature_values, price.feature_values,
         feature.definition].each do |values|
          if values.key?(feature_key)
            value = merge(definition.fetch("merge_rule"), value,
                          values.fetch(feature_key, nil))
          end
        end
        resolved[feature_key] =
          { "definition" => definition, "value" => value, "feature_recording_id" => feature.recording.id }
      end
    end

    private

    attr_reader :product, :billing_option, :price

    def product_features
      scope = Feature.where(product_recording_id: product.recording.id)
      scope = scope.where(state: "published") unless @allow_unpublished
      scope.order(:key)
    end

    def merge(rule, current, incoming)
      case rule
      when "replace" then incoming
      when "merge" then current.to_h.merge(incoming.to_h)
      when "append" then Array(current) + Array(incoming)
      when "minimum" then [current, incoming].min
      when "maximum" then [current, incoming].max
      else raise ArgumentError, "unknown feature merge rule: #{rule}"
      end
    end
  end
end
