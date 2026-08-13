# frozen_string_literal: true

module RecordingStudioBilling
  class PlanUpdate < RecordingStudioBilling::ApplicationRecord
    ALLOWANCE_POLICIES = %w[preserve replace reconcile].freeze

    include CommercialRecordable

    commercial_recordable label: "Plan update", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :billing_option_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    commercial_reference :billing_option_recording, type: "RecordingStudioBilling::BillingOption"

    has_many :applications, class_name: "RecordingStudioBilling::PlanUpdateApplication", dependent: :restrict_with_error
    has_many :runs, class_name: "RecordingStudioBilling::PlanUpdateRun", dependent: :restrict_with_error

    validates :allowance_policy, inclusion: { in: ALLOWANCE_POLICIES }
    validates :execution_state,
              inclusion: { in: %w[draft previewed confirmed scheduled applying completed requires_review failed] }
    validate :safe_execution_payloads

    private

    def safe_execution_payloads
      return unless has_attribute?("replacement_configuration")

      SafeFinancialPayload.validate!(replacement_configuration)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:base, e.message)
    end
  end
end
