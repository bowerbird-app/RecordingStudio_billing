# frozen_string_literal: true

module RecordingStudioBilling
  class PurchaseEffect < RecordingStudioBilling::ApplicationRecord
    EFFECT_KINDS = %w[one_off_addon credit_pack].freeze

    belongs_to :purchase
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :effect_kind, inclusion: { in: EFFECT_KINDS }
    validates :idempotency_key, presence: true
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
    validate :safe_metadata_payload

    private

    def safe_metadata_payload
      SafeFinancialPayload.validate!(safe_metadata)
    rescue SafeFinancialPayload::UnsafeValue => error
      errors.add(:safe_metadata, error.message)
    end
  end
end