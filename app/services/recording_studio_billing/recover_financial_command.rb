# frozen_string_literal: true

module RecordingStudioBilling
  class RecoverFinancialCommand
    def self.call(command:, adapter:, lease_duration: FinancialCommandClaim::DEFAULT_LEASE)
      FinancialCommandExecutor.reject_ambient_transaction!
      ExpireFinancialCommandClaim.call(command:)
      claim = FinancialCommandClaim.call(command:, lease_duration:, recovery: true)
      raise ArgumentError, "command is not ready for recovery" unless claim

      FinancialCommandExecutor.new(command:, adapter:).execute(claim:)
    end
  end
end