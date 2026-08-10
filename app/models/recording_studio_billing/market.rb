# frozen_string_literal: true

module RecordingStudioBilling
  class Market < ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Market", allowed_parent_types: "RecordingStudioBilling::ProviderAccount"

    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :country_code, format: { with: /\A[A-Z]{2}\z/ }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
  end
end
