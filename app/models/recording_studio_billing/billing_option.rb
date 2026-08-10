# frozen_string_literal: true

module RecordingStudioBilling
  class BillingOption < ApplicationRecord
    include CommercialRecordable

    KINDS = %w[recurring usage].freeze

    commercial_recordable label: "Billing option", allowed_parent_types: "RecordingStudioBilling::Product"

    belongs_to :product_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :kind, inclusion: { in: KINDS }
  end
end
