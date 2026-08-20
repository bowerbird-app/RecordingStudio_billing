# frozen_string_literal: true

module RecordingStudioBilling
  class PaymentAllocation < RecordingStudioBilling::ApplicationRecord
    belongs_to :payment
    belongs_to :invoice, optional: true

    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  end
end
