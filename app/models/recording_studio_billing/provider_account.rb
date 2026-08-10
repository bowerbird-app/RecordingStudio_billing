# frozen_string_literal: true

module RecordingStudioBilling
  class ProviderAccount < ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Provider account", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :billing_admin_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :provider, presence: true, format: { with: /\A[a-z][a-z0-9_]*\z/ }
  end
end
