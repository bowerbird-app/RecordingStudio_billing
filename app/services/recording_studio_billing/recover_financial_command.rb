# frozen_string_literal: true

module RecordingStudioBilling
  class RecoverFinancialCommand
    def self.call(command:, provider_key:, lease_duration: FinancialCommandClaim::DEFAULT_LEASE, after_claim: nil)
      adapter_key = provider_key.to_s
      unless command.provider_adapter_key == adapter_key
        raise ArgumentError, "provider adapter key does not match the financial command"
      end

      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(adapter_key)
      recover_with_adapter(command:, adapter:, lease_duration:, after_claim:)
    end

    def self.call_tax(command:, lease_duration: FinancialCommandClaim::DEFAULT_LEASE)
      calculator = RecordingStudioBilling.configuration.tax_calculator_registry.fetch(command.calculator_key)
      recover_with_adapter(
        command:, adapter: CalculateTax::ValidatingAdapter.new(calculator), lease_duration:
      )
    end

    def self.recover_with_adapter(command:, adapter:, lease_duration:, after_claim: nil)
      FinancialCommandExecutor.reject_ambient_transaction!
      ExpireFinancialCommandClaim.call(command:)
      claim = FinancialCommandClaim.call(command:, lease_duration:, recovery: true, after_claim:)
      raise ArgumentError, "command is not ready for recovery" unless claim

      FinancialCommandExecutor.new(command:, adapter:).execute(claim:)
    end
  end
end