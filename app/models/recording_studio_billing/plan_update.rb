# frozen_string_literal: true

module RecordingStudioBilling
  class PlanUpdate < ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Plan update", allowed_parent_types: "RecordingStudioBilling::BillingOption"

    belongs_to :billing_option_recording, class_name: "RecordingStudio::Recording", inverse_of: false
  end
end
