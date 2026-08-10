# frozen_string_literal: true

module RecordingStudioBilling
  class UsageUnit < ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Usage unit", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
  end
end
