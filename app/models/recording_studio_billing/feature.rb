# frozen_string_literal: true

module RecordingStudioBilling
  class Feature < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    TYPES = %w[boolean limit allowance variant].freeze

    commercial_recordable label: "Feature", allowed_parent_types: "RecordingStudioBilling::Product"

    belongs_to :product_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    commercial_reference :product_recording, type: "RecordingStudioBilling::Product"

    validates :kind, inclusion: { in: TYPES }
  end
end
