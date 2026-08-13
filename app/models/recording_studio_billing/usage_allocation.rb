# frozen_string_literal: true

module RecordingStudioBilling
  class UsageAllocation < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :rated_usage
    belongs_to :usage_period
    has_many :usage_credit_allocations, dependent: :restrict_with_error
    has_many :usage_ledger_entries, dependent: :restrict_with_error
    has_many :usage_corrections, dependent: :restrict_with_error
    has_one :overage_calculation, dependent: :restrict_with_error
  end
end
