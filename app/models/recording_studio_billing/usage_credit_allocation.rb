# frozen_string_literal: true

module RecordingStudioBilling
  class UsageCreditAllocation < RecordingStudioBilling::ApplicationRecord
    belongs_to :usage_allocation
    belongs_to :usage_credit_grant
  end
end
