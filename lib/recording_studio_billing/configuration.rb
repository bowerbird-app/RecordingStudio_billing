# frozen_string_literal: true

# rubocop:disable Lint/MissingCopEnableDirective

require_relative "hooks"
require_relative "../../app/services/recording_studio_billing/commercial_manifest_canonicalizer"
require_relative "../../app/services/recording_studio_billing/safe_financial_payload"
require_relative "../../app/services/recording_studio_billing/provider_capabilities"
require_relative "../../app/services/recording_studio_billing/provider_registry"
require_relative "../../app/services/recording_studio_billing/adapter_response"
require_relative "../../app/services/recording_studio_billing/stripe_adapter"
require_relative "../../app/services/recording_studio_billing/tax_calculator_capabilities"
require_relative "../../app/services/recording_studio_billing/tax_calculator_registry"
require_relative "../../app/services/recording_studio_billing/tax_response"
require_relative "../../app/services/recording_studio_billing/stripe_tax_calculator"

module RecordingStudioBilling
  class Configuration
    attr_reader :provider, :hooks, :tax_policy, :discount_policy, :feature_definitions, :gates,
                :default_free_plan_product_key, :market_default_country, :commercial_authorizer,
                :provider_registry, :tax_calculator_registry, :stripe_credential_resolver, :billing_copy, :support_url,
                :billing_presenter_overrides, :billing_provider_components, :stripe_trusted_origins, :stripe_tax_code_resolver,
                :stripe_portal_customer_resolver, :stripe_portal_configuration_id, :billing_portal_context_resolver,
                :billing_location_context_resolver, :plans_page_requires_sign_in, :plans_page_route_helper

    def initialize
      @provider = :stripe
      @provider_registry = ProviderRegistry.new
      @tax_calculator_registry = TaxCalculatorRegistry.new
      register_builtin_providers!
      @hooks = Hooks.new
      @tax_policy = {
        enabled: false,
        calculator_key: nil,
        presentation: "provider_default",
        semantic_categories: [],
        location_requirements: []
      }.freeze
      @discount_policy = { enabled: false, policy_version: "v1", rules: [] }.freeze
      @feature_definitions = {}
      @gates = {}
      @default_free_plan_product_key = nil
      @market_default_country = nil
      @commercial_authorizer = nil
      @billing_copy = {}.freeze
      @support_url = nil
      @billing_presenter_overrides = {}.freeze
      @billing_provider_components = { stripe: { checkout: "RecordingStudioBilling::StripeCheckoutComponent" }.freeze }.freeze
      @stripe_trusted_origins = [].freeze
      @stripe_tax_code_resolver = nil
      @stripe_portal_customer_resolver = nil
      @stripe_portal_configuration_id = nil
      @billing_portal_context_resolver = nil
      @billing_location_context_resolver = nil
      @plans_page_requires_sign_in = true
      @plans_page_route_helper = :plans_path
    end

    def to_h
      {
        provider: provider,
        tax_policy: tax_policy,
        discount_policy: discount_policy,
        feature_definitions: feature_definitions.keys,
        gates: gates.keys,
        default_free_plan_product_key: default_free_plan_product_key,
        market_default_country: market_default_country,
        billing_copy: billing_copy,
        support_url: support_url,
        billing_presenter_overrides: billing_presenter_overrides.keys,
        billing_provider_components: billing_provider_components.keys,
        plans_page_requires_sign_in: plans_page_requires_sign_in,
        plans_page_route_helper: plans_page_route_helper,
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
      raise ArgumentError, "tax presentation must be inclusive, exclusive, or provider_default" unless %w[inclusive exclusive provider_default].include?(presentation)

      @tax_policy = {
        enabled: policy.fetch(:enabled, false) == true,
        calculator_key: policy[:calculator_key]&.to_s,
        presentation: presentation,
        semantic_categories: Array(policy[:semantic_categories]).map(&:to_s).sort,
        location_requirements: Array(policy[:location_requirements]).map(&:to_s).sort
      }.freeze
    end

    def discount_policy=(value)
      policy = value.respond_to?(:to_h) ? value.to_h.transform_keys(&:to_sym) : nil
      raise ArgumentError, "discount_policy must be an object" unless policy

      rules = Array(policy.fetch(:rules, [])).map do |rule|
        raise ArgumentError, "discount rules must be objects" unless rule.respond_to?(:to_h)

        rule.to_h.stringify_keys.sort.to_h.freeze
      end
      @discount_policy = {
        enabled: policy.fetch(:enabled, false) == true,
        policy_version: policy.fetch(:policy_version, "v1").to_s,
        rules: rules.sort_by { |rule| CommercialManifestCanonicalizer.digest(rule) }
      }.freeze
    end

    def feature_definitions=(definitions)
      registry = definitions.respond_to?(:to_h) ? definitions.to_h : {}
      @feature_definitions = registry.each_with_object({}) do |(key, definition), result|
        normalized_key = key.to_s
        raise ArgumentError, "feature key is invalid" unless normalized_key.match?(/\A[a-z][a-z0-9_]*\z/)

        result[normalized_key] = FeatureDefinitionRegistry.normalize(definition).freeze
      end.freeze
    end

    def gates=(definitions)
      registry = definitions.respond_to?(:to_h) ? definitions.to_h : {}
      @gates = registry.each_with_object({}) do |(key, definition), result|
        normalized_key = key.to_s
        raise ArgumentError, "gate key is invalid" unless normalized_key.match?(/\A[a-z][a-z0-9_]*\z/)

        normalized = GateRegistry.normalize(definition.merge(key: normalized_key))
        normalized["feature_key"] ||= normalized_key if normalized.fetch("kind") == "boolean"
        result[normalized_key] = normalized
      end.freeze
    end

    def default_free_plan_product_key=(value)
      key = value&.to_s&.strip
      raise ArgumentError, "default_free_plan_product_key is invalid" if key.present? && !key.match?(/\A[a-z][a-z0-9_]*\z/)

      @default_free_plan_product_key = key.presence
    end

    def market_default_country=(value)
      country = value&.to_s&.upcase
      if country.present? && !country.match?(/\A[A-Z]{2}\z/)
        raise ArgumentError,
              "market_default_country must be an ISO country code"
      end

      @market_default_country = country
    end

    def commercial_authorizer=(value)
      raise ArgumentError, "commercial_authorizer must respond to call" unless value.respond_to?(:call)

      @commercial_authorizer = value
    end

    def billing_copy=(value)
      values = value.respond_to?(:to_h) ? value.to_h : {}
      @billing_copy = values.to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
    end

    def support_url=(value)
      @support_url = value.presence&.to_s
    end

    # Maps a billing page key to a presenter class or callable. A callable is
    # invoked with the default presenter class and must return a class. Presenters
    # may use copy, support_url, navigation_items, and page_contents so hosts can
    # extend customer UI without copying engine templates.
    def billing_presenter_overrides=(value)
      overrides = value.respond_to?(:to_h) ? value.to_h : {}
      @billing_presenter_overrides = overrides.transform_keys(&:to_sym).freeze
    end

    def billing_presenter_override(page, presenter = nil)
      return billing_presenter_overrides[page.to_sym] unless presenter

      self.billing_presenter_overrides = billing_presenter_overrides.merge(page.to_sym => presenter)
    end

    def billing_presenter_for(page, default)
      override = billing_presenter_override(page)
      return default unless override

      override.respond_to?(:call) ? override.call(default) : override
    end

    # Maps provider keys and UI surfaces (for example :stripe, :checkout) to
    # ViewComponent classes. Components receive the corresponding presenter.
    def billing_provider_components=(value)
      components = value.respond_to?(:to_h) ? value.to_h : {}
      @billing_provider_components = components.each_with_object({}) do |(provider_key, surfaces), result|
        result[provider_key.to_sym] = surfaces.to_h.transform_keys(&:to_sym).freeze
      end.freeze
    end

    def billing_provider_component(provider_key, name, component = nil)
      provider = provider_key.to_s.to_sym
      return billing_provider_components.dig(provider, name.to_sym) unless component

      self.billing_provider_components = billing_provider_components.merge(
        provider => billing_provider_components.fetch(provider, {}).merge(name.to_sym => component)
      )
    end

    def stripe_credential_resolver=(value)
      raise ArgumentError, "stripe credential resolver must respond to call" if !value.nil? && !value.respond_to?(:call)

      @stripe_credential_resolver = value
    end

    def stripe_trusted_origins=(values)
      @stripe_trusted_origins = Array(values).map { |value| normalize_https_origin(value) }.uniq.sort.freeze
    end

    def stripe_tax_code_resolver=(value)
      raise ArgumentError, "stripe tax code resolver must respond to call" unless value.nil? || value.respond_to?(:call)

      @stripe_tax_code_resolver = value
    end

    def stripe_portal_customer_resolver=(value)
      unless value.nil? || value.respond_to?(:call)
        raise ArgumentError,
              "stripe portal customer resolver must respond to call"
      end

      @stripe_portal_customer_resolver = value
    end

    def stripe_portal_configuration_id=(value)
      @stripe_portal_configuration_id = if value.nil?
                                          nil
                                        else
                                          SafeFinancialPayload.normalize_reference(value.to_s,
                                                                                   label: "Stripe portal configuration")
                                        end
    end

    def billing_portal_context_resolver=(value)
      unless value.nil? || value.respond_to?(:call)
        raise ArgumentError,
              "billing portal context resolver must respond to call"
      end

      @billing_portal_context_resolver = value
    end

    def billing_location_context_resolver=(value)
      unless value.nil? || value.respond_to?(:call)
        raise ArgumentError,
              "billing location context resolver must respond to call"
      end

      @billing_location_context_resolver = value
    end

    def plans_page_requires_sign_in=(value)
      @plans_page_requires_sign_in = value == true
    end

    def plans_page_route_helper=(value)
      helper = value.to_sym
      raise ArgumentError, "plans_page_route_helper must be present" if helper.to_s.empty?

      @plans_page_route_helper = helper
    end

    def reset_registries!
      provider_registry.reset!
      tax_calculator_registry.reset!
      register_builtin_providers!
      self
    end

    def register_builtin_providers!
      unless provider_registry.registered?(:stripe)
        provider_registry.register(
          :stripe,
          StripeAdapter.new(
            credential_resolver: -> { stripe_credential_resolver&.call },
            trusted_origins_resolver: -> { stripe_trusted_origins },
            tax_code_resolver: ->(category) { stripe_tax_code_resolver&.call(category) }
          )
        )
      end
      unless tax_calculator_registry.keys.include?("stripe_tax")
        tax_calculator_registry.register(
          :stripe_tax,
          StripeAdapter::TaxCalculator.new(
            credential_resolver: -> { stripe_credential_resolver&.call },
            tax_code_resolver: ->(category) { stripe_tax_code_resolver&.call(category) }
          )
        )
      end
      self
    end

    def merge!(hash)
      raise ArgumentError, "commercial configuration must be an object" unless hash.respond_to?(:each)

      hash.each do |k, v|
        key = k.to_s
        setter = "#{key}="
        raise ArgumentError, "unsupported commercial configuration key: #{key}" unless respond_to?(setter)

        public_send(setter, v)
      end
    end

    private

    def normalize_https_origin(value)
      uri = URI.parse(value.to_s)
      unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil? && uri.path.to_s.in?(["",
                                                                              "/"]) && uri.query.nil? && uri.fragment.nil?
        raise ArgumentError, "stripe trusted origin must be an HTTPS origin"
      end

      uri.origin
    rescue URI::InvalidURIError
      raise ArgumentError, "stripe trusted origin must be an HTTPS origin"
    end
  end
end
