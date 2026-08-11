# frozen_string_literal: true

module RecordingStudioBilling
  class PersistTaxCalculation
    def self.call(command:, supersedes: nil)
      payload = command.canonical_request.fetch("request")
      result = command.normalized_result
      revision_number = supersedes ? supersedes.revision_number + 1 : 1
      existing = TaxCalculation.find_by(financial_command_id: command.id, revision_number:)
      return existing if existing

      TaxCalculation.create!(
        financial_command: command, root_recording_id: command.root_recording_id,
        account_recording_id: command.account_recording_id,
        commercial_manifest_id: payload.fetch("commercial_manifest_id"), supersedes:, revision_number:,
        calculator_key: command.calculator_key, calculator_mode: command.calculator_mode,
        manifest_digest: payload.fetch("commercial_manifest_digest"),
        transaction_type: payload.fetch("transaction_type"), operation_reference: payload.fetch("operation_reference"),
        request_fingerprint: CommercialManifestCanonicalizer.digest(payload),
        idempotency_key: payload.fetch("idempotency_key"), subtotal_minor: result.fetch("subtotal_minor"),
        discount_minor: result.fetch("discount_minor"), tax_minor: result.fetch("tax_minor"),
        total_minor: result.fetch("total_minor"), currency: result.fetch("currency"),
        behavior: result.fetch("behavior"), status: result.fetch("status"), breakdown: result.fetch("breakdown", []),
        calculator_reference: result.fetch("calculator_reference"), calculated_at: result.fetch("calculated_at"),
        safe_metadata: command.attempts.order(:attempt_number).last.safe_metadata
      )
    rescue ActiveRecord::RecordNotUnique
      TaxCalculation.find_by!(financial_command_id: command.id, revision_number:)
    end
  end
end