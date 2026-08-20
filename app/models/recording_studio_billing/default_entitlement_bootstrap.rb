# frozen_string_literal: true

module RecordingStudioBilling
  class DefaultEntitlementBootstrap < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :product_key, :manifest_digest, presence: true
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
    validates :applied_at, presence: true
    validate :safe_snapshot

    private

    def safe_snapshot
      SafeFinancialPayload.validate!(commercial_snapshot)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:commercial_snapshot, e.message)
    end
  end
end
