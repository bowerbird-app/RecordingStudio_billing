# frozen_string_literal: true

module RecordingStudioBilling
  class UsageCreditGrant < RecordingStudioBilling::ApplicationRecord
    GRANT_KINDS = %w[allowance credit].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    has_many :usage_credit_allocations, dependent: :restrict_with_error
    has_many :usage_ledger_entries, dependent: :restrict_with_error

    scope :available_at, lambda { |time|
      where(reversed_at: nil).where("effective_at <= ? AND (expires_at IS NULL OR expires_at > ?)", time, time)
    }

    validates :grant_kind, inclusion: { in: GRANT_KINDS }

    def available_quantity
      consumed = UsageLedgerEntry.where(usage_credit_grant: self, entry_kind: "consume").sum(:quantity)
      expired = UsageLedgerEntry.where(usage_credit_grant: self, entry_kind: "expire").sum(:quantity)
      reversed = UsageLedgerEntry.where(usage_credit_grant: self, entry_kind: "reverse").sum(:quantity)
      adjustments = UsageLedgerEntry.where(usage_credit_grant: self, entry_kind: "adjustment").sum(:quantity)
      quantity - consumed - expired - reversed + adjustments
    end
  end
end
