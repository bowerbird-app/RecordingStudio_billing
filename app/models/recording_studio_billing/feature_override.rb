# frozen_string_literal: true

module RecordingStudioBilling
  class FeatureOverride < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Feature override", allowed_parent_types: "RecordingStudioBilling::Account"

    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :feature_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :value, presence: true
  end
end
