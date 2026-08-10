# frozen_string_literal: true

module RecordingStudioBilling
  class ProductRule < ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Product rule", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :product_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :rule_type, presence: true, format: { with: CommercialRecordable::KEY_FORMAT }
  end
end
