# frozen_string_literal: true

module RecordingStudioBilling
  class CostRate < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Cost rate", allowed_parent_types: "RecordingStudioBilling::CostCard"

    belongs_to :cost_card_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :usage_unit_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :currency_exponent, numericality: { only_integer: true, in: 0..3 }
  end
end
