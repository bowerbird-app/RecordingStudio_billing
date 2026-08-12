# frozen_string_literal: true

module RecordingStudioBilling
  class RatedUsage < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :meter_aggregation

    validate :safe_payloads_are_safe

    private

    def safe_payloads_are_safe
      %i[aggregation_snapshot rate_snapshot safe_metadata].each do |attribute|
        SafeFinancialPayload.validate!(public_send(attribute), allow_authoritative_totals: true)
      end
    rescue SafeFinancialPayload::UnsafeValue => error
      errors.add(:base, error.message)
    end
  end
end