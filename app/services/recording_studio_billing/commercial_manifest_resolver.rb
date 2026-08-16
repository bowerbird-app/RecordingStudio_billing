# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Lint/MissingCopEnableDirective

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
         !provider.capabilities.intersect?(%w[commercial_configuration])
        raise ArgumentError, "provider lacks commercial configuration capability"
      end

      unless billing_option.product_recording_id == product.recording.id
        raise ArgumentError,
              "billing option is not owned by product"
      end
      raise ArgumentError, "billing option and price pricing models do not agree" unless billing_option.pricing_model == price.pricing_model

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
      raise ArgumentError, "fixed quantity billing options require the default quantity" if billing_option.quantity_mode == "fixed" && quantity.to_i != billing_option.default_quantity.to_i
      raise ArgumentError, "quantity is below the billing option minimum" if billing_option.minimum_quantity && quantity.to_i < billing_option.minimum_quantity
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
      raise ArgumentError, "trusted currency does not match selected currency" if trusted_context["currency_code"].present? && trusted_context["currency_code"] != currency_code
      return unless trusted_context["quantity"].present? && trusted_context["quantity"].to_i != quantity.to_i

      raise ArgumentError, "trusted quantity does not match selected quantity"
    end

    def market_covers?(country)
      market_coverage_tier(country).present?
    end

    def market_coverage_tier(country)
      normalized = country.to_s.upcase
      return "exact" if Array(market.country_codes).include?(normalized)
      return "group" if market.country_groups.to_h.values.any? { |countries| Array(countries).include?(normalized) }
      return "regional" if Array(market.regional_country_codes).include?(normalized)

      "global" if market.global_fallback?
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
                            key country_codes country_groups regional_country_codes global_fallback
                            allowed_currency_codes default_currency_code priority specificity
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
                  usage_unit_recording_id market_recording_id review_threshold_minor hard_threshold_minor
                  maximum_period_liability_minor maximum_submission_minor
                ]).merge("overage_price_recording_id" => overage_price.recording.id,
                         "consumption_policy" => overage_consumption_policy(overage_price))
        end,
        "usage_rating" => usage_rating_terms,
        "usage_settlement" => {
          "provider_account_recording_id" => product.provider_account_recording_id,
          "provider_adapter_key" => product.provider_account_recording.recordable.adapter_key,
          "market_recording_id" => market.recording.id,
          "resolved_country_code" => trusted_context["country_code"],
          "resolution_tier" => market_coverage_tier(trusted_context["country_code"]),
          "market_geography" => terms(market, %w[country_codes country_groups regional_country_codes global_fallback]),
          "collection_method" => billing_option.collection_method,
          "operation" => "collect_usage"
        },
        "tax_policy" => tax_policy_snapshot,
        "discount_policy" => discount_policy_snapshot,
        "rounding" => { "policy_version" => "v1", "policy" => market.rounding_policy },
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
      unless @product_rules.nil?
        rules = Array(@product_rules)
        validate_injected_product_rules!(rules)
        return rules.sort_by { |rule| rule.recording.id }
      end

      scope = ProductRule.with_current_recording.where(product_recording_id: product.recording.id)
      scope = publication_candidate ? scope.where.not(state: "retired") : scope.where(state: "published")
      scope.order(:id).to_a
    end

    def resolved_plan_updates
      unless @plan_updates.nil?
        plan_updates = Array(@plan_updates)
        validate_injected_plan_updates!(plan_updates)
        return plan_updates.sort_by { |plan_update| plan_update.recording.id }
      end

      scope = PlanUpdate.with_current_recording.where(billing_option_recording_id: billing_option.recording.id)
      scope = publication_candidate ? scope.where.not(state: "retired") : scope.where(state: "published")
      scope.order(:id).to_a
    end

    def validate_injected_product_rules!(rules)
      return if rules.all? do |rule|
        rule.is_a?(ProductRule) && rule.product_recording_id == product.recording.id
      end

      raise ArgumentError, "injected product rules must belong to the selected product"
    end

    def validate_injected_plan_updates!(plan_updates)
      return if plan_updates.all? do |plan_update|
        plan_update.is_a?(PlanUpdate) &&
        plan_update.billing_option_recording_id == billing_option.recording.id
      end

      raise ArgumentError, "injected plan updates must belong to the selected billing option"
    end

    def tax_policy_snapshot
      policy = RecordingStudioBilling.configuration.tax_policy
      unless policy.fetch(:enabled)
        return {
          "policy_version" => "v1",
          "enabled" => false,
          "calculator_key" => nil,
          "presentation" => "provider_default",
          "semantic_categories" => [],
          "location_requirements" => []
        }
      end
      raise ArgumentError, "an enabled tax policy requires a calculator key" if policy.fetch(:calculator_key).blank?

      {
        "policy_version" => "v1",
        "enabled" => true,
        "calculator_key" => policy.fetch(:calculator_key),
        "presentation" => policy.fetch(:presentation),
        "semantic_categories" => policy.fetch(:semantic_categories),
        "location_requirements" => policy.fetch(:location_requirements)
      }
    end

    def discount_policy_snapshot
      RecordingStudioBilling.configuration.discount_policy.stringify_keys
    end

    def consumption_policy
      {
        "policy_version" => "v1",
        "overage_enabled" => overage_prices.present?,
        "overage_policies" => overage_prices.to_h do |overage_price|
          [overage_price.usage_unit_recording_id, overage_consumption_policy(overage_price)]
        end
      }
    end

    def overage_consumption_policy(overage_price)
      {
        "policy_version" => "v1",
        "usage_unit_recording_id" => overage_price.usage_unit_recording_id,
        "pricing_model" => overage_price.pricing_model,
        "unit_size" => overage_price.package_size || 1,
        "quantity_behavior" => overage_price.pricing_model == "package" ? "round_up" : "proportional",
        "minimum_billing_increment" => overage_price.package_size || 1,
        "review_threshold_minor" => overage_price.review_threshold_minor,
        "hard_threshold_minor" => overage_price.hard_threshold_minor,
        "maximum_period_liability_minor" => overage_price.maximum_period_liability_minor,
        "maximum_submission_minor" => overage_price.maximum_submission_minor
      }
    end

    def usage_rating_terms
      selections = rating_selections
      {
        "policy_version" => "v1",
        "selections" => selections.to_h do |selection|
          [selection.fetch(:overage).recording.id, {
            "usage_unit_recording_id" => selection.fetch(:overage).usage_unit_recording_id,
            "market_recording_id" => market.recording.id,
            "currency_code" => currency_code,
            "scope" => Price::V1_SCOPE,
            "meter_recording_id" => selection.fetch(:meter).recording.id,
            "rate_recording_id" => selection.fetch(:rate).recording.id,
            "cost_rate_recording_id" => selection[:cost_rate]&.recording&.id,
            "customer_price_recording_id" => selection.fetch(:overage).recording.id
          }]
        end,
        "meters" => selections.to_h do |selection|
          meter = selection.fetch(:meter)
          [meter.recording.id, terms(meter, %w[key aggregation usage_unit_recording_id]).merge(
            "meter_recording_id" => meter.recording.id,
            "usage_key" => meter.key
          )]
        end,
        "rate_cards" => selections.map do |selection|
          selection.fetch(:rate).rate_card_recording.recordable
        end.uniq.to_h { |card| [card.recording.id, terms(card, %w[key])] },
        "rates" => selections.to_h do |selection|
          rate = selection.fetch(:rate)
          [rate.recording.id,
           terms(rate,
                 %w[key rate_card_recording_id usage_unit_recording_id conversion_numerator conversion_denominator
                    conversion_decimal]).merge("rate_recording_id" => rate.recording.id)]
        end,
        "cost_cards" => selections.filter_map do |selection|
          selection[:cost_rate]&.cost_card_recording&.recordable
        end.uniq.to_h do |card|
          [card.recording.id,
           terms(card, %w[key])]
        end,
        "cost_rates" => selections.filter_map { |selection| selection[:cost_rate] }.to_h do |rate|
          [rate.recording.id,
           terms(rate,
                 %w[key cost_card_recording_id usage_unit_recording_id amount_minor currency_code
                    currency_exponent]).merge("cost_rate_recording_id" => rate.recording.id)]
        end,
        "customer_rates" => overage_prices.to_h do |price|
          [price.recording.id,
           terms(price,
                 %w[key usage_unit_recording_id amount_minor currency_code currency_exponent pricing_model package_size version
                    scope]).merge("customer_price_recording_id" => price.recording.id)]
        end
      }
    end

    def rating_selections
      @rating_selections ||= overage_prices.map do |overage|
        unit_id = overage.usage_unit_recording_id
        meters = applicable_rating_records(Meter, unit_id)
        rates = applicable_rating_records(Rate, unit_id).select do |rate|
          rate.rate_card_recording.recordable.provider_account_recording_id == product.provider_account_recording_id
        end
        costs = applicable_rating_records(CostRate, unit_id).select do |rate|
          rate.currency_code == currency_code &&
            rate.cost_card_recording.recordable.provider_account_recording_id == product.provider_account_recording_id
        end
        raise ArgumentError, "exactly one applicable meter is required" unless meters.one?
        raise ArgumentError, "exactly one applicable conversion rate is required" unless rates.one?
        raise ArgumentError, "ambiguous applicable cost rate" if costs.many?

        { overage:, meter: meters.first, rate: rates.first, cost_rate: costs.first }
      end
    end

    def applicable_rating_records(klass, usage_unit_id)
      scope = klass.with_current_recording.where(usage_unit_recording_id: usage_unit_id)
      scope = publication_candidate ? scope.where.not(state: "retired") : scope.where(state: "published")
      scope.order(:id).to_a
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
        rating_records = usage_rating_records
        [
          product, billing_option, price, market, provider, *overage_prices,
          *usage_units, *resolved_product_rules, *rule_targets, *resolved_plan_updates,
          *features.order(:id).to_a, *overrides, *rating_records
        ].compact.uniq
      end
    end

    def usage_rating_records
      @usage_rating_records ||= rating_selections.flat_map do |selection|
        rate = selection.fetch(:rate)
        cost_rate = selection[:cost_rate]
        [selection.fetch(:meter), rate, rate.rate_card_recording.recordable,
         cost_rate, cost_rate&.cost_card_recording&.recordable]
      end.compact.uniq
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
