# frozen_string_literal: true

module RecordingStudioBilling
  class PlanUpdateApplication < RecordingStudioBilling::ApplicationRecord
    belongs_to :plan_update
    belongs_to :plan_update_run
    belongs_to :subscription_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :subscription_change_intent

    validates :state, inclusion: { in: %w[pending applied failed requires_review] }
  end
end
