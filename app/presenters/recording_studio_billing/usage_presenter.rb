# frozen_string_literal: true

module RecordingStudioBilling
  class UsagePresenter < BasePresenter
    attr_accessor :entitlements, :periods, :credit_grants, :allocations, :meters

    def page = :usage

    def credits
      entitlements.fetch("credits", {})
    end

    def meter_rows
      Array(meters).map do |meter|
        cap = meter.included + meter.purchased
        {
          label: usage_label(meter.meter_key),
          used: meter.used,
          limit: cap.positive? ? cap : nil,
          remaining: meter.remaining,
          description: meter_description(meter)
        }
      end
    end

    def credit_rows
      credits.map { |key, balance| [usage_label(key), balance] }
    end

    def usage_rows
      entitlements.except("credits").map { |key, value| [usage_label(key), simple_usage_value(value)] }
    end

    def included_rows
      entitlements.except("credits").filter_map do |key, value|
        next if nominated_meter_key?(key)

        display = included_usage_value(value)
        next if display.blank?

        { label: usage_label(key), value: display }
      end
    end

    def period_rows
      Array(periods).map do |period|
        policy = Array(period.usage_allowance_policies).first
        limit = policy&.limit_quantity
        {
          usage_key: usage_label(period.usage_key),
          window: "#{period.starts_at.to_fs(:long)} - #{period.ends_at.to_fs(:long)}",
          state: money_state(period.state),
          used: policy&.consumed_quantity.to_i,
          limit: limit.to_i.positive? ? limit.to_i : nil,
          unit: nil,
          included: period.usage_allowance_policies.map do |item|
            "#{item.consumed_quantity} of #{item.limit_quantity} included this period"
          end.join("; ")
        }
      end
    end

    def grant_rows
      Array(credit_grants).filter_map do |grant|
        next if nominated_meter_key?(grant.credit_key)

        {
          key: usage_label(grant.credit_key),
          available: grant.remaining_quantity,
          quantity: grant.quantity,
          expires_at: grant.expires_at&.to_fs(:long) || copy("usage_no_expiry", "No expiry")
        }
      end
    end

    def allocation_rows
      Array(allocations).map do |allocation|
        overage = allocation.overage_calculation
        {
          key: usage_label(allocation.credit_key),
          measured: allocation.measured_quantity,
          credited: allocation.credited_quantity,
          excess: allocation.excess_quantity,
          state: money_state(allocation.state),
          prepaid: allocation.usage_credit_allocations.sum(&:quantity),
          extra_usage: overage && display_amount(overage.amount_minor, overage.currency_code)
        }
      end
    end

    private

    def simple_usage_value(value)
      value.is_a?(Hash) || value.is_a?(Array) ? nil : value.to_s
    end

    def included_usage_value(value)
      case value
      when true then copy("usage_included_yes", "Yes")
      when false then copy("usage_included_no", "No")
      when Hash, Array then nil
      else
        value.to_s.presence
      end
    end

    def meter_description(meter)
      bits = []
      bits << "#{meter.included} on the plan" if meter.included.positive?
      bits << "#{meter.purchased} from packs" if meter.purchased.positive?
      bits.join(", ")
    end

    def nominated_meter_key?(key)
      definition = RecordingStudioBilling.configuration.feature_definitions[key.to_s]
      definition && definition["meter_key"].present?
    end
  end
end
