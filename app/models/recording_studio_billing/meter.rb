# frozen_string_literal: true

module RecordingStudioBilling
  class Meter < ApplicationRecord
    include CommercialRecordable

    AGGREGATIONS = %w[sum count maximum latest].freeze

    commercial_recordable label: "Meter", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :usage_unit_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :aggregation, inclusion: { in: AGGREGATIONS }
  end
end
