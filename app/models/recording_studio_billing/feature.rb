# frozen_string_literal: true

module RecordingStudioBilling
  class Feature < ApplicationRecord
    include CommercialRecordable

    KINDS = %w[boolean quantity].freeze

    commercial_recordable label: "Feature", allowed_parent_types: "RecordingStudioBilling::Product"

    belongs_to :product_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :kind, inclusion: { in: KINDS }
  end
end
