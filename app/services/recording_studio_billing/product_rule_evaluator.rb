# frozen_string_literal: true

# rubocop:disable Metrics/CyclomaticComplexity, Lint/MissingCopEnableDirective

module RecordingStudioBilling
  class ProductRuleEvaluator
    Result = Data.define(:eligible, :transition, :violations)

    def initialize(product:, selected_products:, current_product: nil)
      @product = product
      @selected_products = Array(selected_products)
      @current_product = current_product
    end

    def evaluate
      violations = published_rules.filter_map { |rule| violation_for(rule) }
      Result.new(violations.empty?, transition, violations)
    end

    private

    attr_reader :product, :selected_products, :current_product

    def published_rules
      ProductRule.where(product_recording_id: product.recording.id, state: "published").order(:key)
    end

    def violation_for(rule)
      target = rule.target_product_recording_id
      selected = selected_products.map { |item| item.respond_to?(:recording) ? item.recording.id : item.to_s }
      case rule.rule_type
      when "requires", "available_with" then rule.key unless selected.include?(target)
      when "excludes" then rule.key if selected.include?(target)
      end
    end

    def transition
      return nil unless current_product

      rule = published_rules.find { |candidate| candidate.target_product_recording_id == current_product.recording.id }
      return rule.rule_type if rule && %w[replaces upgrade_from downgrade_from same_family].include?(rule.rule_type)

      nil
    end
  end
end
