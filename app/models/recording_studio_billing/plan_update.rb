# frozen_string_literal: true

module RecordingStudioBilling
  class PlanUpdate < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Plan update", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :billing_option_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    commercial_reference :billing_option_recording, type: "RecordingStudioBilling::BillingOption"
  end
end
