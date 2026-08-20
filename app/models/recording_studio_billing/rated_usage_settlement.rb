# frozen_string_literal: true

module RecordingStudioBilling
  class RatedUsageSettlement < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :rated_usage, optional: true
    belongs_to :usage_period
    belongs_to :financial_command
    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validate :safe_payloads_are_safe

    private

    def safe_payloads_are_safe
      %i[canonical_request safe_metadata].each do |attribute|
        SafeFinancialPayload.validate!(public_send(attribute), allow_authoritative_totals: true)
      end
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:base, e.message)
    end
  end
end
