# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity, Lint/MissingCopEnableDirective

module RecordingStudioBilling
  class CommercialManifestResolver
    SCHEMA_VERSION = CommercialManifest::SCHEMA_VERSION
    RESOLVER_VERSION = CommercialManifest::RESOLVER_VERSION

    def initialize(product:, billing_option:, price:, market:, currency_code:, quantity: nil,
                   overage_price: nil, publication_candidate: false)
      @product = product
      @billing_option = billing_option
      @price = price
      @market = market
      @currency_code = currency_code
      @quantity = quantity || billing_option.default_quantity || 1
      @overage_price = overage_price
      @publication_candidate = publication_candidate
    end

    def resolve!
      validate_versions!
      validate_commercial_state!
      validate_graph!

      body = manifest_body
      canonical_data = JSON.parse(CommercialManifestCanonicalizer.canonicalize(body))
      {
        canonical_data: canonical_data,
        manifest_digest: CommercialManifestCanonicalizer.digest(canonical_data),
        recording_snapshots: recording_snapshots,
        snapshot_references: snapshot_references
      }
    end

    private

    attr_reader :product, :billing_option, :price, :market, :currency_code, :quantity, :overage_price,
                :publication_candidate

    def validate_versions!
      raise ArgumentError, "unsupported commercial manifest schema" unless SCHEMA_VERSION == "v1"
      raise ArgumentError, "unsupported commercial resolver version" unless RESOLVER_VERSION == "v1"
    end

    def validate_commercial_state!
      records = [product, billing_option, price, market, overage_price].compact
      return if publication_candidate && records.all? { |record| %w[draft published].include?(record.state) }
      return if records.all? { |record| record.state == "published" }

      raise ArgumentError, "draft or retired commercial records cannot be resolved"
    end

    def validate_graph!
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
      unless billing_option.product_recording_id == product.recording.id
        raise ArgumentError,
              "billing option is not owned by product"
      end
      return unless overage_price

      valid_overage = overage_price.billing_option_recording_id == billing_option.recording.id &&
                      overage_price.market_recording_id == market.recording.id &&
                      overage_price.currency_code == currency_code
      raise ArgumentError, "overage price does not match selected commercial graph" unless valid_overage
    end

    def manifest_body
      {
        "schema_version" => SCHEMA_VERSION,
        "resolver_version" => RESOLVER_VERSION,
        "root_recording_id" => product.recording.root_recording_id,
        "references" => snapshot_references,
        "product" => terms(product, %w[key kind]),
        "billing_option" => terms(billing_option, %w[
                                    key recurrence interval interval_count quantity_mode minimum_quantity maximum_quantity default_quantity
                                    pricing_model collection_method payment_terms_days trial_days proration_policy lifecycle_policy
                                    checkout_policy tax_policy
                                  ]),
        "market" => terms(market, %w[
                            key country_codes country_groups allowed_currency_codes default_currency_code priority specificity fallback
                            ppa_policy rounding_policy tax_presentation_policy verification_policy
                          ]),
        "price" => terms(price, %w[
                           key amount_minor currency_code currency_exponent pricing_model package_size version scope
                         ]).merge("quantity" => quantity),
        "features" => resolved_features,
        "overage_price" => overage_price && terms(overage_price, %w[
                                                    key amount_minor currency_code currency_exponent pricing_model package_size version scope usage_unit_recording_id
                                                  ]),
        "tax_policy" => tax_policy_snapshot,
        "discount_policy" => { "enabled" => false, "source" => "none" },
        "rounding" => { "policy" => market.rounding_policy },
        "consumption_policy" => consumption_policy
      }
    end

    def resolved_features
      FeatureResolver.new(
        product: product, billing_option: billing_option, price: price, allow_unpublished: publication_candidate
      ).resolve!
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
        "overage_enabled" => overage_price.present?,
        "overage_usage_unit_recording_id" => overage_price&.usage_unit_recording_id
      }
    end

    def terms(record, keys)
      keys.index_with { |key| record.public_send(key) }
    end

    def recording_snapshots
      referenced_records.map { |record| recording_snapshot(record) }
    end

    def snapshot_references
      referenced_records.to_h do |record|
        [record.class.name.demodulize.underscore, recording_snapshot(record)]
      end
    end

    def recording_snapshot(record)
      recording = record.recording
      {
        "recording_id" => recording.id,
        "recordable_type" => recording.recordable_type,
        "recordable_id" => recording.recordable_id,
        "recordable_updated_at" => record.updated_at.utc.iso8601(6)
      }
    end

    def referenced_records
      features = Feature.where(product_recording_id: product.recording.id).to_a
      usage_unit = overage_price&.usage_unit_recording&.recordable
      provider = product.provider_account_recording.recordable
      [product, billing_option, price, market, provider, overage_price, usage_unit, *features].compact.uniq
    end
  end
end
