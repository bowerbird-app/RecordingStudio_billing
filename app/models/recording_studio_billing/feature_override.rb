# frozen_string_literal: true

module RecordingStudioBilling
  class FeatureOverride < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Feature override", allowed_parent_types: "RecordingStudioBilling::Account"

    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :feature_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    # Overrides live beneath an Account, so the account reference remains in
    # that isolated root. Features live in the central billing-admin catalogue.
    commercial_reference :account_recording, type: "RecordingStudioBilling::Account"
    commercial_reference :feature_recording, type: "RecordingStudioBilling::Feature", same_root: false

    validate :value_is_present

    private

    def value_is_present
      errors.add(:value, "must be present") if value.nil?
    end
  end
end
