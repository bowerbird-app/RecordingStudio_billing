# frozen_string_literal: true

module RecordingStudioBilling
  class UsageEvent < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :usage_key, :idempotency_key, presence: true
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validate :safe_metadata_is_safe

    private

    def safe_metadata_is_safe
      SafeFinancialPayload.validate!(safe_metadata)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:safe_metadata, e.message)
    end
  end
end
