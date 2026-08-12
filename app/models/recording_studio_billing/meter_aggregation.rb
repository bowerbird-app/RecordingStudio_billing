# frozen_string_literal: true

module RecordingStudioBilling
  class MeterAggregation < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :aggregation, inclusion: { in: Meter::AGGREGATIONS }
    validates :input_digest, format: { with: /\A\h{64}\z/ }
    validates :event_count, numericality: { only_integer: true, greater_than: 0 }
    validate :safe_payloads_are_safe

    private

    def safe_payloads_are_safe
      %i[input_snapshot safe_metadata].each { |attribute| SafeFinancialPayload.validate!(public_send(attribute)) }
    rescue SafeFinancialPayload::UnsafeValue => error
      errors.add(:base, error.message)
    end
  end
end