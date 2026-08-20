# frozen_string_literal: true

module RecordingStudioBilling
  class Payment < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :financial_command
    belongs_to :invoice, optional: true
    has_many :allocations, class_name: "RecordingStudioBilling::PaymentAllocation", dependent: :restrict_with_error
    has_many :refund_intents, class_name: "RecordingStudioBilling::RefundIntent", dependent: :restrict_with_error

    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :safe_snapshot

    private

    def safe_snapshot
      SafeFinancialPayload.validate!(self[:safe_snapshot],
                                     allow_authoritative_totals: financial_command&.command_type == "checkout")
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:safe_snapshot, e.message)
    end
  end
end
