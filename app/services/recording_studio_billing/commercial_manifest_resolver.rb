# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity, Lint/MissingCopEnableDirective

module RecordingStudioBilling
  class CommercialManifestResolver
    SCHEMA_VERSION = CommercialManifest::SCHEMA_VERSION
    RESOLVER_VERSION = CommercialManifest::RESOLVER_VERSION

    def initialize(product:, billing_option:, price:, market:, currency_code:, quantity: nil,
                   overage_price: nil, overage_prices: nil, publication_candidate: false,
                   trusted_context: {}, account_recording: nil, product_rules: nil, plan_updates: nil)
      @product = product
      @billing_option = billing_option
      @price = price
      @market = market
      @currency_code = currency_code
      @quantity = quantity || billing_option.default_quantity || 1
      @overage_prices = Array(overage_prices || overage_price).compact.sort_by { |item| item.recording.id }
      @publication_candidate = publication_candidate
      @trusted_context = trusted_context.to_h.stringify_keys
      @account_recording = account_recording
      @product_rules = product_rules
      @plan_updates = plan_updates
    end

    def resolve!
      validate_versions!
      validate_commercial_state!
      validate_graph!

      body = manifest_body
      canonical_data = JSON.parse(CommercialManifestCanonicalizer.canonicalize(body))
      snapshots = recording_snapshots
      references = snapshot_references
      envelope = manifest_envelope(canonical_data, snapshots, references)
      {
        canonical_data: canonical_data,
        manifest_digest: CommercialManifestCanonicalizer.digest(envelope),
        recording_snapshots: snapshots,
        snapshot_references: references
      }
    end

    private

    attr_reader :product, :billing_option, :price, :market, :currency_code, :quantity, :overage_prices,
                :publication_candidate, :trusted_context, :account_recording

    def validate_versions!
      raise ArgumentError, "unsupported commercial manifest schema" unless SCHEMA_VERSION == "v1"
      raise ArgumentError, "unsupported commercial resolver version" unless RESOLVER_VERSION == "v1"
    end

    def validate_commercial_state!
      primary_records = [product, billing_option, price, market, *overage_prices].compact
      unless primary_records.all? { |record| currently_recorded?(record) }
        raise ArgumentError,
              "historical commercial revisions cannot be resolved"
      end

      records = referenced_records
      allowed_states = publication_candidate ? %w[draft published] : ["published"]
      invalid = records.reject { |record| currently_recorded?(record) && allowed_states.include?(record.state) }
      return if invalid.empty?

      details = invalid.map { |record| "#{record.class.name}(#{record.state})" }.join(", ")
      raise ArgumentError, "draft, retired, or historical commercial records cannot be resolved: #{details}"
    end

    def validate_graph!
      validate_trusted_context!
      unless price.billing_option_recording_id == billing_option.recording.id
        raise ArgumentError,
              "price is not owned by billing option"
      end
      unless price.market_recording_id == market.recording.id
        raise ArgumentError,
              "price market does not match resolver market"
      end
      raise ArgumentError, "price currency does not match" unless price.currency_code == currency_code

      unless market.allowed_currency_codes.include?(currency_code)
        raise ArgumentError,
              "market does not permit selected currency"
      end
      unless product.provider_account_recording_id == market.provider_account_recording_id
        raise ArgumentError,
              "product and market use different providers"
      end
      provider = product.provider_account_recording&.recordable
      unless provider.is_a?(ProviderAccount) && provider.active?
        raise ArgumentError,
              "product provider is missing or inactive"
      end
      if provider.capabilities.present? &&
         !provider.capabilities.intersect?(%w[catalogue commercial_catalogue])
        raise ArgumentError, "provider lacks commercial catalogue capability"
      end

      unless billing_option.product_recording_id == product.recording.id
        raise ArgumentError,
              "billing option is not owned by product"
      end
      unless billing_option.pricing_model == price.pricing_model
        raise ArgumentError, "billing option and price pricing models do not agree"
      end

      validate_quantity!
      overage_prices.each do |overage_price|
        valid_overage = overage_price.billing_option_recording_id == billing_option.recording.id &&
                        overage_price.market_recording_id == market.recording.id &&
                        overage_price.currency_code == currency_code &&
                        overage_price.scope == price.scope &&
                        overage_price.usage_unit_recording&.recordable.is_a?(UsageUnit) &&
                        overage_price.pricing_model == price.pricing_model &&
                        overage_price.usage_unit_recording.recordable.provider_account_recording_id ==
                        product.provider_account_recording_id
        raise ArgumentError, "overage price does not match selected commercial graph" unless valid_overage
      end
      validate_catalogue_roots!
    end

    def validate_quantity!
      unless quantity.to_i.positive? && quantity.to_i == quantity
        raise ArgumentError,
              "quantity must be a positive integer"
      end
      if billing_option.quantity_mode == "fixed" && quantity.to_i != billing_option.default_quantity.to_i
        raise ArgumentError, "fixed quantity billing options require the default quantity"
      end
      if billing_option.minimum_quantity && quantity.to_i < billing_option.minimum_quantity
        raise ArgumentError, "quantity is below the billing option minimum"
      end
      return unless billing_option.maximum_quantity && quantity.to_i > billing_option.maximum_quantity

      raise ArgumentError, "quantity exceeds the billing option maximum"
    end

    def validate_trusted_context!
      prohibited = trusted_context.keys & %w[amount_minor provider tax tax_amount tax_rate]
      raise ArgumentError, "untrusted commercial context contains protected terms" if prohibited.any?
      return if trusted_context.empty?

      country = trusted_context["country_code"]
      raise ArgumentError, "trusted country does not match market" if country.present? && !market_covers?(country)
      if trusted_context["market_recording_id"].present? &&
         trusted_context["market_recording_id"] != market.recording.id
        raise ArgumentError, "trusted market does not match selected market"
      end
      if trusted_context["currency_code"].present? && trusted_context["currency_code"] != currency_code
        raise ArgumentError, "trusted currency does not match selected currency"
      end
      return unless trusted_context["quantity"].present? && trusted_context["quantity"].to_i != quantity.to_i

      raise ArgumentError, "trusted quantity does not match selected quantity"
    end

    def market_covers?(country)
      normalized = country.to_s.upcase
      Array(market.country_codes).include?(normalized) ||
        market.country_groups.to_h.values.any? { |countries| Array(countries).include?(normalized) } ||
        market.fallback?
    end

    def manifest_body
      {
        "schema_version" => SCHEMA_VERSION,
        "resolver_version" => RESOLVER_VERSION,
        "root_recording_id" => product.recording.root_recording_id,
        "references" => snapshot_references,
        "product" => terms(product, %w[key kind]),
        "billing_option" => terms(billing_option, %w[
                                    key recurrence interval interval_count quantity_mode minimum_quantity
                                    maximum_quantity
                                    default_quantity pricing_model collection_method payment_terms_days trial_days
                                    proration_policy lifecycle_policy
                                    checkout_policy tax_policy
                                  ]),
        "market" => terms(market, %w[
                            key country_codes country_groups allowed_currency_codes default_currency_code priority
                            specificity fallback
                            ppa_policy rounding_policy tax_presentation_policy verification_policy
                          ]),
        "price" => terms(price, %w[
                           key amount_minor currency_code currency_exponent pricing_model package_size version scope
                         ]).merge("quantity" => quantity),
        "features" => resolved_features,
        "product_rules" => resolved_product_rules.map do |rule|
          terms(rule, %w[key rule_type target_product_recording_id conditions])
        end,
        "plan_updates" => resolved_plan_updates.map do |plan_update|
          terms(plan_update, %w[key billing_option_recording_id])
        end,
        "overage_prices" => overage_prices.map do |overage_price|
          terms(overage_price, %w[
                  key amount_minor currency_code currency_exponent pricing_model package_size version scope
                  usage_unit_recording_id
                ])
        end,
        "tax_policy" => tax_policy_snapshot,
        "discount_policy" => { "enabled" => false, "source" => "none" },
        "rounding" => { "policy" => market.rounding_policy },
        "consumption_policy" => consumption_policy,
        "trusted_context" => trusted_context.slice("country_code", "market_recording_id", "currency_code", "quantity")
      }
    end

    def resolved_features
      FeatureResolver.new(
        product: product, billing_option: billing_option, price: price, account_recording: account_recording,
        allow_unpublished: publication_candidate
      ).resolve!
    end

    def resolved_product_rules
      return Array(@product_rules).sort_by { |rule| rule.recording.id } unless @product_rules.nil?

      scope = ProductRule.with_current_recording.where(product_recording_id: product.recording.id)
      scope = publication_candidate ? scope.where.not(state: "retired") : scope.where(state: "published")
      scope.order(:id).to_a
    end

    def resolved_plan_updates
      return Array(@plan_updates).sort_by { |plan_update| plan_update.recording.id } unless @plan_updates.nil?

      scope = PlanUpdate.with_current_recording.where(billing_option_recording_id: billing_option.recording.id)
      scope = publication_candidate ? scope.where.not(state: "retired") : scope.where(state: "published")
      scope.order(:id).to_a
    end

    def tax_policy_snapshot
      policy = RecordingStudioBilling.configuration.tax_policy
      unless policy.fetch(:enabled)
        return {
          "enabled" => false,
          "calculator_key" => nil,
          "presentation" => "provider_default",
          "semantic_categories" => [],
          "location_requirements" => []
        }
      end
      raise ArgumentError, "an enabled tax policy requires a calculator key" if policy.fetch(:calculator_key).blank?

      {
        "enabled" => true,
        "calculator_key" => policy.fetch(:calculator_key),
        "presentation" => policy.fetch(:presentation),
        "semantic_categories" => policy.fetch(:semantic_categories),
        "location_requirements" => policy.fetch(:location_requirements)
      }
    end

    def consumption_policy
      {
        "pricing_model" => price.pricing_model,
        "overage_enabled" => overage_prices.present?,
        "overage_usage_unit_recording_ids" => overage_prices.map(&:usage_unit_recording_id)
      }
    end

    def terms(record, keys)
      keys.index_with { |key| record.public_send(key) }
    end

    def recording_snapshots
      referenced_records.map { |record| recording_snapshot(record) }
    end

    def snapshot_references
      referenced_records.to_h { |record| [record.recording.id, recording_snapshot(record)] }
    end

    def recording_snapshot(record)
      recording = record.recording
      {
        "recording_id" => recording.id,
        "root_recording_id" => recording.root_recording_id,
        "parent_recording_id" => recording.parent_recording_id,
        "recordable_type" => recording.recordable_type,
        "recordable_id" => recording.recordable_id,
        "recording_created_at" => recording.created_at.utc.iso8601(6),
        "recording_updated_at" => recording.updated_at.utc.iso8601(6),
        "recording_trashed_at" => recording.attributes["trashed_at"]&.utc&.iso8601(6),
        "recordable_created_at" => record.created_at.utc.iso8601(6),
        "recordable_updated_at" => record.updated_at.utc.iso8601(6),
        "recordable_digest" => CommercialManifestCanonicalizer.digest(
          record.attributes.except("created_at", "updated_at")
        )
      }
    end

    def referenced_records
      @referenced_records ||= begin
        features = Feature.with_current_recording.where(product_recording_id: product.recording.id)
        features = publication_candidate ? features.where.not(state: "retired") : features.where(state: "published")
        usage_units = overage_prices.filter_map { |overage_price| overage_price.usage_unit_recording&.recordable }
        rule_targets = resolved_product_rules.filter_map do |rule|
          rule.target_product_recording&.recordable
        end
        provider = product.provider_account_recording&.recordable
        overrides = if account_recording
                      FeatureOverride.with_current_recording.where(
                        account_recording_id: account_recording.id,
                        state: "published"
                      ).order(:id).to_a
                    else
                      []
                    end
        [
          product, billing_option, price, market, provider, *overage_prices,
          *usage_units, *resolved_product_rules, *rule_targets, *resolved_plan_updates,
          *features.order(:id).to_a, *overrides
        ].compact.uniq
      end
    end

    def validate_catalogue_roots!
      root_id = product.recording.root_recording_id
      catalogue_records = referenced_records.reject { |record| record.is_a?(FeatureOverride) }
      unless catalogue_records.all? { |record| record.recording.root_recording_id == root_id }
        raise ArgumentError,
              "commercial manifest references multiple catalogue roots"
      end
      return unless account_recording

      unless account_recording.recordable.is_a?(Account)
        raise ArgumentError,
              "feature overrides require a billing account recording"
      end
      return if referenced_records.grep(FeatureOverride).all? do |override|
        override.account_recording_id == account_recording.id
      end

      raise ArgumentError, "feature override belongs to a different billing account"
    end

    def currently_recorded?(record)
      recording = record.recording
      recording.present? && recording.recordable_type == record.class.name && recording.recordable_id == record.id
    end

    def manifest_envelope(canonical_data, snapshots, references)
      {
        "schema_version" => SCHEMA_VERSION,
        "resolver_version" => RESOLVER_VERSION,
        "root_recording_id" => product.recording.root_recording_id,
        "canonical_data" => canonical_data,
        "recording_snapshots" => snapshots,
        "snapshot_references" => references
      }
    end
  end
end
