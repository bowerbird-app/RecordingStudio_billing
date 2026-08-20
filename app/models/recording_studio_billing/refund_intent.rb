# frozen_string_literal: true

module RecordingStudioBilling
  class RefundIntent < RecordingStudioBilling::ApplicationRecord
    STATES = %w[pending executing completed failed requires_review cancelled].freeze

    belongs_to :payment
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :financial_command, optional: true
    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", optional: true, inverse_of: false
    has_one :refund, class_name: "RecordingStudioBilling::Refund", dependent: :restrict_with_error

    validates :local_idempotency_key, :request_fingerprint, presence: true
    validates :request_fingerprint, format: { with: /\A\h{64}\z/ }
    validates :state, inclusion: { in: STATES }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
  end
end
