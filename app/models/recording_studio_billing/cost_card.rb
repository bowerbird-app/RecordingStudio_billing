# frozen_string_literal: true

module RecordingStudioBilling
  class CostCard < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Cost card", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
  end
end
