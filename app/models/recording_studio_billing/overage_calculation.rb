# frozen_string_literal: true

module RecordingStudioBilling
  class OverageCalculation < RecordingStudioBilling::ApplicationRecord
    belongs_to :usage_allocation
    belongs_to :overage_price_recording, class_name: "RecordingStudio::Recording", inverse_of: false
  end
end
