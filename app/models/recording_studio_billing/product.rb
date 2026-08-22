# frozen_string_literal: true

module RecordingStudioBilling
  class Product < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    KINDS = %w[plan addon credit_pack service].freeze

    commercial_recordable label: "Product", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    commercial_reference :provider_account_recording, type: "RecordingStudioBilling::ProviderAccount"

    validates :name, presence: true
    validates :kind, inclusion: { in: KINDS }
  end
end
