# frozen_string_literal: true

module RecordingStudioBilling
  class RecoverTaxCalculation
    Result = Data.define(:status, :calculation, :response) do
      def final? = calculation&.final? == true
    end

    def self.call(calculation:)
      calculation = TaxCalculation.find(calculation.id)
      unless %w[pending unknown].include?(calculation.status) && calculation.corrections.empty?
        raise ArgumentError, "tax calculation is not ready for recovery"
      end

      command = calculation.financial_command
      calculator = RecordingStudioBilling.configuration.tax_calculator_registry.fetch(command.calculator_key)
      if calculator.capabilities.mode != command.calculator_mode || calculation.calculator_mode != command.calculator_mode
        raise ArgumentError, "tax calculator mode does not match the original calculation"
      end
      RecoverFinancialCommand.call_tax(command:)
      recovered = PersistTaxCalculation.call(
        command: command.reload, supersedes: calculation
      )
      Result.new(status: recovered.status.to_sym, calculation: recovered, response: command.normalized_result)
    end
  end
end