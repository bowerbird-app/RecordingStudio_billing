# frozen_string_literal: true

# rubocop:disable Lint/MissingCopEnableDirective

module RecordingStudioBilling
  class ProductRuleEvaluator
    Result = Data.define(:eligible, :transition, :violations)

    def initialize(product:, selected_products:, current_product: nil, context: {}, rules: nil)
      @product = product
      @selected_products = Array(selected_products)
      @current_product = current_product
      @context = context.to_h.stringify_keys
      @rules = rules
    end

    def evaluate
      violations = published_rules.filter_map { |rule| violation_for(rule) }
      Result.new(violations.empty?, transition, violations)
    end

    private

    attr_reader :product, :selected_products, :current_product, :context, :rules

    def published_rules
      return Array(rules).sort_by(&:key) if rules

      ProductRule.with_current_recording.where(
        product_recording_id: product.recording.id,
        state: "published"
      ).order(:key)
    end

    def violation_for(rule)
      validate_rule!(rule)
      return unless conditions_met?(rule)

      target = rule.target_product_recording_id
      selected = selected_products.map { |item| item.respond_to?(:recording) ? item.recording.id : item.to_s }
      case rule.rule_type
      when "requires", "available_with" then rule.key unless selected.include?(target)
      when "excludes" then rule.key if selected.include?(target)
      end
    end

    def conditions_met?(rule)
      conditions = rule.conditions
      validate_conditions!(conditions)

      conditions.all? do |key, required|
        next Array(required).map(&:to_s).all? { |id| selected_recording_ids.include?(id) } if key.to_s == "selected_product_recording_ids"

        actual = context[key.to_s]
        Array(required).map(&:to_s).include?(actual.to_s) ||
          (required.is_a?(Array) && Array(actual).map(&:to_s).intersect?(required.map(&:to_s)))
      end
    end

    def validate_rule!(rule)
      return if ProductRule::RULE_TYPES.include?(rule.rule_type) && rule.target_product_recording_id.present?

      raise ArgumentError, "product rule is malformed"
    end

    def validate_conditions!(conditions)
      return if ProductRule.valid_conditions?(conditions)

      raise ArgumentError, "product rule conditions are malformed"
    end

    def selected_recording_ids
      selected_products.map { |item| item.respond_to?(:recording) ? item.recording.id : item.to_s }
    end

    def transition
      return nil unless current_product

      rule = published_rules.find do |candidate|
        next unless %w[replaces upgrade_from downgrade_from same_family].include?(candidate.rule_type)

        candidate.target_product_recording_id == current_product.recording.id &&
          conditions_met?(candidate)
      end
      return rule.rule_type if rule

      nil
    end
  end
end
