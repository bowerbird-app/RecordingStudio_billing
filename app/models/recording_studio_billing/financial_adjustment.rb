# frozen_string_literal: true

module RecordingStudioBilling
  class FinancialAdjustment < RecordingStudioBilling::ApplicationRecord
    belongs_to :adjustment_intent
    belongs_to :invoice
    belongs_to :financial_command

    validates :kind, inclusion: { in: AdjustmentIntent::KINDS }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  end
end
