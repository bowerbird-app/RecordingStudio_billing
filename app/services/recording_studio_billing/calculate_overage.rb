# frozen_string_literal: true

module RecordingStudioBilling
  class CalculateOverage
    class AuthorityError < ArgumentError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason.to_s)
      end
    end

    def self.call(...) = new(...).call

    def initialize(allocation:)
      @allocation = allocation
    end

    def call
      OverageCalculation.transaction(requires_new: true) do
        locked_allocation = UsageAllocation.lock.find(allocation.id)
        return if locked_allocation.excess_quantity.zero?

        OverageCalculation.find_or_create_by!(usage_allocation: locked_allocation) do |calculation|
          rate = authoritative_rate!(locked_allocation)
          amount = Integer(rate.fetch("amount_minor"))
          package_size = Integer(rate.fetch("package_size", 1) || 1)
          raise AuthorityError, :invalid_overage_package_size unless package_size.positive?

          calculation.excess_quantity = locked_allocation.excess_quantity
          calculation.amount_minor = amount_for(locked_allocation.excess_quantity, amount, package_size,
                                                rate.fetch("pricing_model"))
          calculation.currency_code = rate.fetch("currency_code")
          calculation.currency_exponent = Integer(rate.fetch("currency_exponent"))
          calculation.overage_price_recording_id = rate.fetch("overage_price_recording_id")
          calculation.rate_snapshot = SafeFinancialPayload.normalize(rate, allow_authoritative_totals: true)
        end
      end
    end

    private

    attr_reader :allocation

    def authoritative_rate!(allocation)
      rated = allocation.rated_usage
      manifest = CommercialManifest.lock.find_by(manifest_digest: rated.manifest_digest)
      raise AuthorityError, :overage_manifest_unavailable unless manifest&.used_at?

      data = manifest.canonical_data.stringify_keys
      meter = data.dig("usage_rating", "meters", rated.meter_aggregation.meter_recording_id.to_s)
      settlement = data["usage_settlement"].to_h.stringify_keys
      raise AuthorityError, :overage_usage_unit_unavailable unless meter.is_a?(Hash) && meter["usage_unit_recording_id"].present?
      raise AuthorityError, :overage_market_unavailable unless settlement["market_recording_id"].present?

      currency = rated.rate_snapshot.dig("customer_rate", "currency_code")
      candidates = Array(data["overage_prices"]).map(&:stringify_keys).select do |price|
        price["usage_unit_recording_id"] == meter["usage_unit_recording_id"] &&
          price["currency_code"] == currency &&
          price["market_recording_id"] == settlement["market_recording_id"] &&
          price["scope"] == rated.rate_snapshot.dig("customer_rate", "scope")
      end
      raise AuthorityError, :overage_price_missing if candidates.empty?
      raise AuthorityError, :overage_price_ambiguous unless candidates.one?

      price = candidates.sole
      raise AuthorityError, :overage_currency_incompatible unless price["currency_code"] == currency &&
                                                                  price["currency_exponent"] == rated.rate_snapshot.dig("customer_rate", "currency_exponent")

      safety_limits = price.fetch("consumption_policy", {}).stringify_keys.slice(
        "review_threshold_minor", "hard_threshold_minor", "maximum_period_liability_minor", "maximum_submission_minor"
      )
      price.merge(
        "manifest_digest" => manifest.manifest_digest,
        "market_recording_id" => settlement.fetch("market_recording_id"),
        "usage_unit_recording_id" => meter.fetch("usage_unit_recording_id"),
        "safety_limits" => safety_limits
      )
    rescue KeyError, TypeError
      raise AuthorityError, :overage_price_incompatible
    end

    def amount_for(quantity, amount, package_size, pricing_model)
      case pricing_model
      when "flat" then amount
      when "per_unit" then quantity * amount
      when "package" then ((quantity * amount) + package_size - 1) / package_size
      else raise AuthorityError, :overage_price_incompatible
      end
    end
  end
end
