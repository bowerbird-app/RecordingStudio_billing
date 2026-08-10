# frozen_string_literal: true

module RecordingStudioBilling
  class UsageUnit < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Usage unit", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    commercial_reference :provider_account_recording, type: "RecordingStudioBilling::ProviderAccount"
  end
end
