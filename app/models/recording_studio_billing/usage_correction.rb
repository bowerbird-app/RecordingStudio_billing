# frozen_string_literal: true

module RecordingStudioBilling
  class UsageCorrection < RecordingStudioBilling::ApplicationRecord
    CORRECTION_KINDS = %w[credit debit void].freeze

    belongs_to :usage_allocation
    belongs_to :supersedes, class_name: "RecordingStudioBilling::UsageCorrection", optional: true
    belongs_to :tax_calculation, optional: true
    belongs_to :financial_command, optional: true

    validates :correction_kind, inclusion: { in: CORRECTION_KINDS }
    validates :quantity_delta, numericality: { only_integer: true, other_than: 0 }
    validates :reason, presence: true
    validate :safe_metadata_is_safe

    private

    def safe_metadata_is_safe
      SafeFinancialPayload.validate!(safe_metadata)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:safe_metadata, e.message)
    end
  end
end
