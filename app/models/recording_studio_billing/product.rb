# frozen_string_literal: true

module RecordingStudioBilling
  class Product < ApplicationRecord
    include CommercialRecordable

    KINDS = %w[subscription one_time].freeze

    commercial_recordable label: "Product", allowed_parent_types: "RecordingStudioBilling::ProviderAccount"

    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :kind, inclusion: { in: KINDS }
  end
end
