# frozen_string_literal: true

module RecordingStudioBilling
  class RateCard < ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Rate card", allowed_parent_types: "RecordingStudioBilling::ProviderAccount"

    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
  end
end
