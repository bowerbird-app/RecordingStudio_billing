# frozen_string_literal: true

module RecordingStudioBilling
  class UsageLedgerEntry < RecordingStudioBilling::ApplicationRecord
    ENTRY_KINDS = %w[grant consume expire reverse adjustment overage].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :usage_period
    belongs_to :usage_allocation, optional: true
    belongs_to :usage_credit_grant, optional: true
    belongs_to :supersedes, class_name: "RecordingStudioBilling::UsageLedgerEntry", optional: true

    validates :entry_kind, inclusion: { in: ENTRY_KINDS }
    validates :quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :sequence, numericality: { only_integer: true, greater_than: 0 }
    validate :safe_metadata_is_safe

    private

    def safe_metadata_is_safe
      SafeFinancialPayload.validate!(safe_metadata)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:safe_metadata, e.message)
    end
  end
end
