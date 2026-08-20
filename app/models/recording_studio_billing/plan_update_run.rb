# frozen_string_literal: true

module RecordingStudioBilling
  class PlanUpdateRun < RecordingStudioBilling::ApplicationRecord
    STATES = %w[draft previewed awaiting_confirmation scheduled applying applied failed requires_review].freeze

    belongs_to :plan_update
    has_many :applications, class_name: "RecordingStudioBilling::PlanUpdateApplication", dependent: :restrict_with_error

    validates :idempotency_key, :request_fingerprint, presence: true
    validates :state, inclusion: { in: STATES }
    validate :safe_payloads

    private

    def safe_payloads
      [preview, confirmation, reconciliation].each { |payload| SafeFinancialPayload.validate!(payload) }
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:base, e.message)
    end
  end
end
