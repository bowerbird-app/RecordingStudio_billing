# frozen_string_literal: true

module RecordingStudioBilling
  class FinancialCommandAttempt < RecordingStudioBilling::ApplicationRecord
    belongs_to :financial_command, inverse_of: :attempts

    validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
    validates :state, inclusion: { in: FinancialCommand::STATES }
    validates :provider_idempotency_key, :started_at, presence: true
    validate :safe_payloads
    validate :matches_command_idempotency_key

    private

    def safe_payloads
      {
        normalized_result: normalized_result,
        safe_error_details: safe_error_details,
        safe_metadata: safe_metadata
      }.each do |attribute, value|
        SafeFinancialPayload.validate!(
          value,
          allow_authoritative_totals: attribute == :normalized_result &&
            financial_command&.command_type.in?(%w[tax_calculation checkout])
        )
      rescue SafeFinancialPayload::UnsafeValue => e
        errors.add(attribute, e.message)
      end
    end

    def matches_command_idempotency_key
      return unless financial_command && provider_idempotency_key != financial_command.provider_idempotency_key

      errors.add(:provider_idempotency_key, "must match the financial command")
    end
  end
end
