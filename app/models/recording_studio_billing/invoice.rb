# frozen_string_literal: true

module RecordingStudioBilling
  class Invoice < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :financial_command, optional: true
    belongs_to :subscription, optional: true
    belongs_to :purchase, optional: true
    has_many :payments, class_name: "RecordingStudioBilling::Payment", dependent: :restrict_with_error
    has_many :lines, class_name: "RecordingStudioBilling::InvoiceLine", dependent: :restrict_with_error
    has_many :adjustment_intents, class_name: "RecordingStudioBilling::AdjustmentIntent",
                                  dependent: :restrict_with_error

    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :total_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :safe_snapshot

    private

    def safe_snapshot
      SafeFinancialPayload.validate!(self[:safe_snapshot])
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:safe_snapshot, e.message)
    end
  end
end
