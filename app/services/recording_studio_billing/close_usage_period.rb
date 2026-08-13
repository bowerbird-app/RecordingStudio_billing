# frozen_string_literal: true

module RecordingStudioBilling
  class CloseUsagePeriod
    Result = Data.define(:status, :usage_period) do
      def closed? = status == :closed
      def existing? = status == :existing
      def blocked? = status == :blocked
    end

    def self.call(...) = new(...).call

    def initialize(usage_period:, at: Time.current)
      @usage_period = usage_period
      @at = at
    end

    def call
      UsagePeriod.transaction(requires_new: true) do
        period = UsagePeriod.lock.find(usage_period.id)
        return Result.new(status: :existing, usage_period: period) if period.state == "closed"
        return Result.new(status: :blocked, usage_period: period) unless period.state == "open"
        return Result.new(status: :blocked, usage_period: period) if at < period.ends_at

        period.update!(state: "closing")
        if period.usage_allocations.where.not(state: "closed").exists?
          return Result.new(status: :blocked,
                            usage_period: period)
        end

        period.update!(state: "closed", closed_at: at)
        Result.new(status: :closed, usage_period: period)
      end
    end

    private

    attr_reader :at, :usage_period
  end
end
