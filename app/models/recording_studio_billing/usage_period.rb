# frozen_string_literal: true

module RecordingStudioBilling
  class UsagePeriod < RecordingStudioBilling::ApplicationRecord
    STATES = %w[open closing closed submitted invoiced reconciled requires_review].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    has_many :usage_allocations, dependent: :restrict_with_error
    has_many :usage_allowance_policies, dependent: :restrict_with_error
    has_many :usage_ledger_entries, dependent: :restrict_with_error

    validates :usage_key, :starts_at, :ends_at, presence: true
    validates :state, inclusion: { in: STATES }
    validate :ends_after_starts
    validate :safe_metadata_is_safe

    private

    def safe_metadata_is_safe
      SafeFinancialPayload.validate!(safe_metadata)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:safe_metadata, e.message)
    end

    def ends_after_starts
      return unless starts_at && ends_at && ends_at <= starts_at

      errors.add(:ends_at, "must be after starts_at")
    end
  end
end
