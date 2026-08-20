# frozen_string_literal: true

module RecordingStudioBilling
  class AllocateRatedUsage
    Result = Data.define(:status, :allocation) do
      def created? = status == :created
      def existing? = status == :existing
    end

    def self.call(...) = new(...).call

    def initialize(rated_usage:, credit_key: nil, at: nil, metadata: {})
      @rated_usage = rated_usage
      @credit_key = credit_key
      @at = at
      @metadata = metadata
    end

    def call
      RatedUsage.transaction(requires_new: true) do
        rated = RatedUsage.lock.find(rated_usage.id)
        existing = UsageAllocation.find_by(rated_usage: rated)
        return Result.new(status: :existing, allocation: existing) if existing

        key = credit_key || rated.rate_snapshot.dig("meter", "usage_key")
        period = usage_period_for!(rated, key)
        allocation_time = at || rated.window_starts_at
        allocation = UsageAllocation.create!(root_recording_id: rated.root_recording_id, account_recording_id: rated.account_recording_id,
                                             rated_usage: rated, usage_period: period, credit_key: key, measured_quantity: rated.quantity,
                                             credited_quantity: 0, excess_quantity: rated.quantity, state: "closing",
                                             safe_metadata: SafeFinancialPayload.normalize(metadata))
        remaining = rated.quantity
        grants = UsageCreditGrant.available_at(allocation_time)
                                 .where(root_recording_id: rated.root_recording_id, account_recording_id: rated.account_recording_id, credit_key: key)
                                 .order(Arel.sql("CASE grant_kind WHEN 'allowance' THEN 0 ELSE 1 END"), Arel.sql("expires_at ASC NULLS LAST"), :created_at, :id).lock
        grants.each do |grant|
          break if remaining.zero?

          quantity = [remaining, grant.available_quantity].min
          next unless quantity.positive?

          UsageCreditAllocation.create!(usage_allocation: allocation, usage_credit_grant: grant, quantity: quantity)
          append_entry!(period, allocation, "consume", quantity, usage_credit_grant: grant)
          remaining -= quantity
        end
        allocation.update!(credited_quantity: rated.quantity - remaining, excess_quantity: remaining, state: "closed")
        append_entry!(period, allocation, "overage", remaining) if remaining.positive?
        Result.new(status: :created, allocation: allocation)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.new(status: :existing, allocation: UsageAllocation.find_by!(rated_usage_id: rated_usage.id))
    end

    private

    attr_reader :at, :credit_key, :metadata, :rated_usage

    def usage_period_for!(rated, key)
      period = UsagePeriod.find_or_create_by!(root_recording_id: rated.root_recording_id, account_recording_id: rated.account_recording_id,
                                              usage_key: key, starts_at: rated.window_starts_at, ends_at: rated.window_ends_at) do |entry|
        entry.state = "open"
        entry.safe_metadata = {}
      end
      period.lock!
      raise ArgumentError, "usage period is not open" unless period.state == "open"

      period
    end

    def append_entry!(period, allocation, entry_kind, quantity, usage_credit_grant: nil)
      sequence = period.usage_ledger_entries.maximum(:sequence).to_i + 1
      UsageLedgerEntry.create!(root_recording_id: allocation.root_recording_id, account_recording_id: allocation.account_recording_id,
                               usage_period: period, usage_allocation: allocation, usage_credit_grant:, entry_kind:, quantity:, sequence:,
                               safe_metadata: {})
    end
  end
end
