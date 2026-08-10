# frozen_string_literal: true

module RecordingStudioBilling
  class FeatureOverride < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Feature override", allowed_parent_types: "RecordingStudioBilling::Account"

    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :feature_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    # Overrides live beneath an Account; both references must remain in its
    # isolated Recording Studio root.
    commercial_reference :account_recording, type: "RecordingStudioBilling::Account"
    commercial_reference :feature_recording, type: "RecordingStudioBilling::Feature"

    validates :value, presence: true
  end
end
