# frozen_string_literal: true

module RecordingStudioBilling
  class InvoiceLine < RecordingStudioBilling::ApplicationRecord
    belongs_to :invoice

    validates :description, presence: true
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validate :safe_snapshot_payload

    private

    def safe_snapshot_payload
      SafeFinancialPayload.validate!(safe_snapshot,
                                     allow_authoritative_totals: invoice&.financial_command&.command_type == "checkout")
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:safe_snapshot, e.message)
    end
  end
end
