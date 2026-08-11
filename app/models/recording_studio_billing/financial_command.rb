# frozen_string_literal: true

module RecordingStudioBilling
  class FinancialCommand < RecordingStudioBilling::ApplicationRecord
    STATES = %w[pending processing succeeded failed uncertain requires_reconciliation cancelled].freeze
    RECONCILIATION_STATES = %w[not_required pending processing reconciled failed].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", optional: true, inverse_of: false
    has_many :attempts, class_name: "RecordingStudioBilling::FinancialCommandAttempt",
                        dependent: :restrict_with_error, inverse_of: :financial_command
    scope :pending_work, -> { where(state: "pending") }
    scope :stale_processing, ->(now = Time.current) { where(state: "processing", lease_expires_at: ..now) }
    scope :reconciliation_work, -> { where(state: "requires_reconciliation").or(where(reconciliation_state: "pending")) }

    validates :operation_id, :command_type, :canonical_request, :request_fingerprint,
              :local_idempotency_key, :provider_idempotency_key, presence: true
    validates :command_type, format: { with: /\A[a-z][a-z0-9_]*\z/ }
    validates :request_fingerprint, format: { with: /\A\h{64}\z/ }
    validates :provider_reference, length: { maximum: 512 }, allow_nil: true
    validates :state, inclusion: { in: STATES }
    validates :reconciliation_state, inclusion: { in: RECONCILIATION_STATES }
    validate :one_execution_authority
    validate :safe_persisted_payloads
    validate :canonical_envelope_integrity

    private

    def one_execution_authority
      provider_authority = provider_account_recording_id? && provider_adapter_key?
      tax_authority = calculator_key? && calculator_mode?
      return if provider_authority ^ tax_authority

      errors.add(:base, "exactly one provider adapter or calculator is required")
    end

    def safe_persisted_payloads
      { normalized_result:, safe_error_details: }.each do |attribute, value|
        SafeFinancialPayload.validate!(
          value,
          allow_authoritative_totals: attribute == :normalized_result && command_type == "tax_calculation"
        )
      rescue SafeFinancialPayload::UnsafeValue => e
        errors.add(attribute, e.message)
      end
    end

    def canonical_envelope_integrity
      envelope = canonical_request
      authority = envelope.is_a?(Hash) ? envelope["authority"] : nil
      payload = envelope.is_a?(Hash) ? envelope["request"] : nil
      valid = envelope.is_a?(Hash) && envelope.keys.sort == %w[authority request schema_version] &&
              envelope["schema_version"] == "v1" && authority.is_a?(Hash) && payload.is_a?(Hash) &&
              authority["root_recording_id"] == root_recording_id &&
              authority["account_recording_id"] == account_recording_id &&
              authority["command_type"] == command_type &&
              authority["provider_account_recording_id"] == provider_account_recording_id &&
              authority["provider_adapter_key"] == provider_adapter_key &&
              authority["calculator_key"] == calculator_key &&
              authority["calculator_mode"] == calculator_mode &&
              authority["commercial_manifest_digests"].is_a?(Array) &&
              authority["commercial_manifest_digests"] == authority["commercial_manifest_digests"].uniq.sort
      errors.add(:canonical_request, "has an invalid canonical envelope") unless valid
      SafeFinancialPayload.validate!(payload, allow_authoritative_totals: command_type == "tax_calculation") if payload.is_a?(Hash)
      return unless request_fingerprint.present? && envelope.is_a?(Hash)

      expected = CommercialManifestCanonicalizer.digest(envelope)
      errors.add(:request_fingerprint, "does not match the canonical request") unless request_fingerprint == expected
    rescue SafeFinancialPayload::UnsafeValue, CommercialManifestCanonicalizer::UnsupportedValue => e
      errors.add(:canonical_request, e.message)
    end
  end
end