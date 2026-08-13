# frozen_string_literal: true

module RecordingStudioBilling
  class OverageCalculation < RecordingStudioBilling::ApplicationRecord
    belongs_to :usage_allocation
  end
end
