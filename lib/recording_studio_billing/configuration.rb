# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Lint/MissingCopEnableDirective

require_relative "hooks"

module RecordingStudioBilling
  class Configuration
    attr_reader :provider, :hooks, :tax_policy, :feature_definitions, :market_default_country

    def initialize
      @provider = :stripe
      @hooks = Hooks.new
      @tax_policy = {
        enabled: false,
        calculator_key: nil,
        presentation: "provider_default",
        semantic_categories: [],
        location_requirements: []
      }.freeze
      @feature_definitions = {}
      @market_default_country = nil
    end

    def to_h
      {
        provider: provider,
        tax_policy: tax_policy,
        feature_definitions: feature_definitions,
        market_default_country: market_default_country,
        hooks_registered: hooks.instance_variable_get(:@registry).transform_values(&:size)
      }
    end

    def provider=(value)
      normalized_provider = value.to_s.strip
      raise ArgumentError, "provider must be present" if normalized_provider.empty?

      @provider = normalized_provider.to_sym
    end

    def tax_policy=(value)
      policy = value.respond_to?(:to_h) ? value.to_h.transform_keys(&:to_sym) : {}
      presentation = policy.fetch(:presentation, "provider_default").to_s
      unless %w[inclusive exclusive provider_default].include?(presentation)
        raise ArgumentError, "tax presentation must be inclusive, exclusive, or provider_default"
      end

      @tax_policy = {
        enabled: policy.fetch(:enabled, false) == true,
        calculator_key: policy[:calculator_key]&.to_s,
        presentation: presentation,
        semantic_categories: Array(policy[:semantic_categories]).map(&:to_s).sort,
        location_requirements: Array(policy[:location_requirements]).map(&:to_s).sort
      }.freeze
    end

    def feature_definitions=(definitions)
      registry = definitions.respond_to?(:to_h) ? definitions.to_h : {}
      @feature_definitions = registry.each_with_object({}) do |(key, definition), result|
        normalized_key = key.to_s
        raise ArgumentError, "feature key is invalid" unless normalized_key.match?(CommercialRecordable::KEY_FORMAT)

        result[normalized_key] = FeatureDefinitionRegistry.normalize(definition).freeze
      end.freeze
    end

    def market_default_country=(value)
      country = value&.to_s&.upcase
      if country.present? && !country.match?(/\A[A-Z]{2}\z/)
        raise ArgumentError,
              "market_default_country must be an ISO country code"
      end

      @market_default_country = country
    end

    def merge!(hash)
      return unless hash.respond_to?(:each)

      hash.each do |k, v|
        key = k.to_s
        setter = "#{key}="
        public_send(setter, v) if respond_to?(setter)
      end
    end
  end
end
