# frozen_string_literal: true

module RecordingStudioBilling
  class Refund < RecordingStudioBilling::ApplicationRecord
    belongs_to :refund_intent
    belongs_to :payment
    belongs_to :financial_command

    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  end
end
