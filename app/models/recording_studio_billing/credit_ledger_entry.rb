# frozen_string_literal: true

module RecordingStudioBilling
  class CreditLedgerEntry < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :purchase_effect, class_name: "RecordingStudioBilling::PurchaseEffect", optional: true
    belongs_to :usage_event, class_name: "RecordingStudioBilling::UsageEvent", optional: true

    validates :credit_key, :product_recording_id, presence: true
    validates :direction, inclusion: { in: %w[credit debit] }
    validates :amount, numericality: { only_integer: true, other_than: 0 }
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
    validate :safe_metadata_is_safe

    private

    def safe_metadata_is_safe
      SafeFinancialPayload.validate!(safe_metadata)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:safe_metadata, e.message)
    end
  end
end
