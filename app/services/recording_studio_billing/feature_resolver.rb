# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Lint/MissingCopEnableDirective

module RecordingStudioBilling
  class FeatureResolver
    def initialize(product:, billing_option:, price:, account_recording: nil, allow_unpublished: false)
      @product = product
      @billing_option = billing_option
      @price = price
      @account_recording = account_recording
      @allow_unpublished = allow_unpublished
    end

    def resolve!
      validate_overrides!
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
        value = apply_overrides(feature, definition, value)
        resolved[feature_key] =
          { "definition" => definition, "value" => value, "feature_recording_id" => feature.recording.id }
      end
    end

    private

    attr_reader :product, :billing_option, :price, :account_recording

    def product_features
      scope = Feature.where(product_recording_id: product.recording.id)
      scope = scope.where(state: "published") unless @allow_unpublished
      scope.order(:key, :id)
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

    def apply_overrides(feature, definition, value)
      return value unless account_recording

      FeatureOverride.where(account_recording_id: account_recording.id, feature_recording_id: feature.recording.id,
                            state: "published").order(:key, :id).each do |override|
        value = merge(definition.fetch("merge_rule"), value, override.value)
      end
      value
    end

    def validate_overrides!
      return unless account_recording

      feature_ids = product_features.map { |feature| feature.recording.id }
      invalid = FeatureOverride.where(account_recording_id: account_recording.id, state: "published")
                               .where.not(feature_recording_id: feature_ids).exists?
      raise ArgumentError, "feature override references an unknown feature for this product" if invalid
    end
  end
end
