# frozen_string_literal: true

module RecordingStudioBilling
  class ReconciliationIssue < RecordingStudioBilling::ApplicationRecord
    belongs_to :financial_command, optional: true

    validates :authority, :kind, presence: true
    validates :state, inclusion: { in: %w[open resolved ignored] }
    validate :safe_payload_is_safe

    private

    def safe_payload_is_safe
      SafeFinancialPayload.validate!(safe_payload)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:safe_payload, e.message)
    end
  end
end
