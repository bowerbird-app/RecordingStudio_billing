# frozen_string_literal: true

module RecordingStudioBilling
  class TaxCalculation < RecordingStudioBilling::ApplicationRecord
    belongs_to :financial_command
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :commercial_manifest
    belongs_to :supersedes, class_name: "RecordingStudioBilling::TaxCalculation", optional: true,
                 inverse_of: :corrections
    has_many :corrections, class_name: "RecordingStudioBilling::TaxCalculation", foreign_key: :supersedes_id,
                 dependent: :restrict_with_error, inverse_of: :supersedes

    validates :calculator_key, :calculator_mode, :manifest_digest, :transaction_type, :operation_reference,
              :request_fingerprint, :idempotency_key, :currency, :behavior, :status, :calculated_at, presence: true
    validates :request_fingerprint, :manifest_digest, format: { with: /\A\h{64}\z/ }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :calculator_mode, inclusion: { in: TaxCalculatorCapabilities::MODES }
    validates :subtotal_minor, :discount_minor, :tax_minor, :total_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :revision_number, numericality: { only_integer: true, greater_than: 0 }
    validate :safe_payloads

    def final?
      %w[success duplicate].include?(status)
    end

    private

    def safe_payloads
      SafeFinancialPayload.validate!(safe_metadata)
      Array(breakdown).each { |entry| SafeFinancialPayload.validate!(entry) }
      SafeFinancialPayload.normalize_reference(operation_reference, label: "tax operation reference")
      SafeFinancialPayload.normalize_reference(calculator_reference, label: "calculator reference")
    rescue SafeFinancialPayload::UnsafeValue => error
      errors.add(:base, error.message)
    end
  end
end