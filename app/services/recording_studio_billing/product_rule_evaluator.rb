# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Lint/MissingCopEnableDirective

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
      return rule.key unless conditions_met?(rule)

      target = rule.target_product_recording_id
      selected = selected_products.map { |item| item.respond_to?(:recording) ? item.recording.id : item.to_s }
      case rule.rule_type
      when "requires", "available_with" then rule.key unless selected.include?(target)
      when "excludes" then rule.key if selected.include?(target)
      end
    end

    def conditions_met?(rule)
      conditions = rule.conditions
      return false unless conditions.is_a?(Hash)
      return false unless (conditions.keys.map(&:to_s) - ProductRule::CONDITION_KEYS).empty?

      conditions.all? do |key, required|
        actual = key.to_s == "selected_product_recording_ids" ? selected_recording_ids : context[key.to_s]
        Array(required).map(&:to_s).include?(actual.to_s) ||
          (required.is_a?(Array) && Array(actual).map(&:to_s).intersect?(required.map(&:to_s)))
      end
    end

    def selected_recording_ids
      selected_products.map { |item| item.respond_to?(:recording) ? item.recording.id : item.to_s }
    end

    def transition
      return nil unless current_product

      rule = published_rules.find { |candidate| candidate.target_product_recording_id == current_product.recording.id }
      return rule.rule_type if rule && %w[replaces upgrade_from downgrade_from same_family].include?(rule.rule_type)

      nil
    end
  end
end
