# frozen_string_literal: true

module RecordingStudioBilling
  class AdjustmentIntent < RecordingStudioBilling::ApplicationRecord
    KINDS = %w[credit debit write_off].freeze
    STATES = RefundIntent::STATES

    belongs_to :invoice
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :financial_command, optional: true
    has_one :financial_adjustment, class_name: "RecordingStudioBilling::FinancialAdjustment",
                                   dependent: :restrict_with_error

    validates :local_idempotency_key, :request_fingerprint, presence: true
    validates :request_fingerprint, format: { with: /\A\h{64}\z/ }
    validates :kind, inclusion: { in: KINDS }
    validates :state, inclusion: { in: STATES }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  end
end
