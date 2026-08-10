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
        unless definition.fetch("type") == feature.kind
          raise ArgumentError,
                "feature kind does not match its registered definition"
        end

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
      @product_features ||= begin
        scope = Feature.with_current_recording.where(product_recording_id: product.recording.id)
        scope = @allow_unpublished ? scope.where.not(state: "retired") : scope.where(state: "published")
        features = scope.order(:key, :id).to_a
        keys = features.map { |feature| feature.definition.fetch("_commercial_source_key", feature.key) }
        raise ArgumentError, "feature keys are ambiguous for this product" if keys.uniq.size != keys.size

        features
      end
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

      FeatureOverride.with_current_recording.where(
        account_recording_id: account_recording.id,
        feature_recording_id: feature.recording.id,
        state: "published"
      ).order(:key, :id).each do |override|
        value = merge(definition.fetch("merge_rule"), value, override.value)
      end
      value
    end

    def validate_overrides!
      return unless account_recording

      feature_ids = product_features.map { |feature| feature.recording.id }
      invalid = FeatureOverride.with_current_recording
                               .where(account_recording_id: account_recording.id, state: "published")
                               .where.not(feature_recording_id: feature_ids).exists?
      raise ArgumentError, "feature override references an unknown feature for this product" if invalid
    end
  end
end
