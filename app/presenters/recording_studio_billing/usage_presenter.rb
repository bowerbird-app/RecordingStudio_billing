# frozen_string_literal: true

module RecordingStudioBilling
  class UsagePresenter < BasePresenter
    attr_accessor :entitlements, :periods, :credit_grants, :allocations

    def page = :usage

    def credits
      entitlements.fetch("credits", {})
    end

    def usage_rows
      entitlements.except("credits").map { |key, value| [key.to_s.humanize, display_value(value)] }
    end

    def period_rows
      periods.to_a.map do |period|
        { usage_key: period.usage_key, window: "#{period.starts_at.to_fs(:long)} - #{period.ends_at.to_fs(:long)}",
          state: period.state.humanize, metadata: display_value(period.safe_metadata), caps: period.usage_allowance_policies.map do |policy|
            "#{policy.usage_key}: #{policy.policy_kind.humanize}, #{policy.consumed_quantity}/#{policy.limit_quantity}"
          end.join("; ") }
      end
    end

    def grant_rows
      credit_grants.to_a.map do |grant|
        { key: grant.credit_key, available: grant.remaining_quantity, quantity: grant.quantity,
          expires_at: grant.expires_at&.to_fs(:long) || "No expiry", metadata: display_value(grant.safe_metadata) }
      end
    end

    def allocation_rows
      allocations.to_a.map do |allocation|
        overage = allocation.overage_calculation
        { key: allocation.credit_key, measured: allocation.measured_quantity, credited: allocation.credited_quantity,
          excess: allocation.excess_quantity, state: allocation.state.humanize,
          grant_allocation: allocation.usage_credit_allocations.sum(&:quantity),
          overage: overage && display_amount(overage.amount_minor, overage.currency_code),
          tax: overage && display_value(overage.rate_snapshot), metadata: display_value(allocation.safe_metadata) }
      end
    end
  end
end
