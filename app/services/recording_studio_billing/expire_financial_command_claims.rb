# frozen_string_literal: true

module RecordingStudioBilling
  class ExpireFinancialCommandClaims
    def self.call(now: Time.current)
      expired = 0
      FinancialCommand.stale_processing(now).find_each do |command|
        expired += 1 if ExpireFinancialCommandClaim.call(command:, now:)
      end
      expired
    end
  end
end