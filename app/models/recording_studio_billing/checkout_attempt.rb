# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutAttempt < RecordingStudioBilling::ApplicationRecord
    STATES = %w[pending processing succeeded failed cancelled unknown].freeze

    belongs_to :checkout_intent, inverse_of: :attempts
    belongs_to :financial_command, inverse_of: false
    validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
    validates :state, inclusion: { in: STATES }
    validate :safe_result

    private

    def safe_result
      SafeFinancialPayload.validate!(self[:safe_result])
      SafeFinancialPayload.validate!(self[:safe_error_details])
    rescue SafeFinancialPayload::UnsafeValue => error
      errors.add(:safe_result, error.message)
    end
  end
end