# frozen_string_literal: true

module RecordingStudioBilling
  class UsagePresenter < BasePresenter
    attr_accessor :entitlements, :periods, :credit_grants, :allocations

    def page = :usage

    def credits
      entitlements.fetch("credits", {})
    end

    def credit_rows
      credits.map { |key, balance| [usage_label(key), balance] }
    end

    def usage_rows
      entitlements.except("credits").map { |key, value| [usage_label(key), simple_usage_value(value)] }
    end

    def period_rows
      Array(periods).map do |period|
        {
          usage_key: usage_label(period.usage_key),
          window: "#{period.starts_at.to_fs(:long)} - #{period.ends_at.to_fs(:long)}",
          state: money_state(period.state),
          included: period.usage_allowance_policies.map do |policy|
            copy("usage_included", "%{used} of %{limit} included this period")
              .sub("%{used}", policy.consumed_quantity.to_s)
              .sub("%{limit}", policy.limit_quantity.to_s)
          end.join("; ")
        }
      end
    end

    def grant_rows
      Array(credit_grants).map do |grant|
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
  end
end
