# frozen_string_literal: true

module RecordingStudioBilling
  class CreateAdjustmentIntent
    Result = Data.define(:status, :intent) do
      def created? = status == :created
      def existing? = status == :existing
      def conflict? = status == :conflict
    end

    def self.call(...) = new(...).call

    def initialize(invoice:, root_recording:, local_idempotency_key:, kind:, amount_minor:, metadata: {}, reason: nil,
                   actor_reference: nil, tax_treatment: "provider_default", approved_authority: {}, affected_reference: {})
      @invoice_input = invoice
      @root_recording_input = root_recording
      @local_idempotency_key = local_idempotency_key.to_s
      @kind = kind.to_s
      @amount_minor = amount_minor
      @metadata = metadata
      @reason = reason
      @actor_reference = actor_reference
      @tax_treatment = tax_treatment
      @approved_authority = approved_authority
      @affected_reference = affected_reference
    end

    def call
      AdjustmentIntent.transaction do
        invoice = Invoice.where(root_recording: RecordingStudio.root_recording_or_self(root_recording_input)).lock.find(invoice_id)
        validate_invoice!(invoice)
        approved_authority = trusted_manual_authority!(invoice)
        validate_request_payloads!
        fingerprint = CommercialManifestCanonicalizer.digest("invoice_id" => invoice.id, "kind" => kind, "amount_minor" => amount_minor,
                                                             "reason" => reason, "tax_treatment" => tax_treatment,
                                                             "approved_authority" => approved_authority,
                                                             "affected_reference" => affected_reference, "actor_reference" => actor_reference,
                                                             "metadata" => SafeFinancialPayload.normalize(metadata))
        existing = AdjustmentIntent.lock.find_by(root_recording: invoice.root_recording, local_idempotency_key:)
        if existing
          return Result.new(status: existing.request_fingerprint == fingerprint ? :existing : :conflict,
                            intent: existing)
        end

        allowed = kind == "debit" || amount_minor.to_i <= remaining_amount(invoice)
        unless AdjustmentIntent::KINDS.include?(kind) && amount_minor.to_i.positive? && allowed
          raise ArgumentError,
                "adjustment cannot invent a charge"
        end

        intent = AdjustmentIntent.create!(invoice:, root_recording: invoice.root_recording, account_recording: invoice.account_recording,
                                          local_idempotency_key:, request_fingerprint: fingerprint, kind:, amount_minor:, currency_code: invoice.currency_code,
                                          reason:, actor_reference:, tax_treatment:, approved_authority:, affected_reference:, safe_metadata: metadata)
        command = CreateFinancialCommand.call(
          root_recording: invoice.root_recording, account_recording: invoice.account_recording, command_type: "adjustment",
          local_idempotency_key: "adjustment:#{intent.id}", provider_account_recording: provider_recording(invoice),
          provider_adapter_key: provider_adapter_key(invoice), request: { adjustment_intent_id: intent.id, invoice_id: invoice.id,
                                                                          provider_invoice_reference: invoice.provider_reference,
                                                                          kind:, amount_minor:, currency: invoice.currency_code, reason:,
                                                                          actor_reference:, tax_treatment:, approved_authority:, affected_reference:,
                                                                          request_fingerprint: fingerprint }
        ).command
        intent.update!(financial_command: command)
        Result.new(status: :created, intent:)
      end
    end

    private

    attr_reader :actor_reference, :affected_reference, :amount_minor, :approved_authority, :invoice_input, :kind,
                :local_idempotency_key, :metadata, :reason, :root_recording_input, :tax_treatment

    def invoice_id = invoice_input.respond_to?(:id) ? invoice_input.id : invoice_input

    def validate_invoice!(invoice)
      raise ArgumentError, "adjustment invoice currency is invalid" unless invoice.currency_code.match?(/\A[A-Z]{3}\z/)

      return if invoice.financial_command&.provider_account_recording_id.present?

      raise ArgumentError,
            "adjustment invoice has no provider authority"
    end

    def validate_request_payloads!
      validate_text!(:reason, reason, required: true)
      validate_text!(:tax_treatment, tax_treatment, required: true)
      validate_text!(:actor_reference, actor_reference, required: true)
      validate_payload!(:affected_reference, affected_reference, required: true)
      validate_payload!(:metadata, metadata)
    end

    def validate_text!(name, value, required: false)
      string = value.to_s
      raise ArgumentError, "adjustment #{name} is required" if required && string.empty?
      raise ArgumentError, "adjustment #{name} is too long" if string.length > 512
    end

    def validate_payload!(name, value, required: false)
      normalized = SafeFinancialPayload.normalize(value)
      raise ArgumentError, "adjustment #{name} is required" if required && normalized.blank?

      unless normalized.is_a?(Hash) || normalized.is_a?(Array)
        raise ArgumentError,
              "adjustment #{name} must be a structured value"
      end
      raise ArgumentError, "adjustment #{name} is too large" if normalized.to_json.bytesize > 16_384
    rescue SafeFinancialPayload::UnsafeValue
      raise ArgumentError, "adjustment #{name} is invalid"
    end

    def remaining_amount(invoice)
      reserved = invoice.adjustment_intents.where(kind: %w[credit write_off],
                                                  state: %w[pending
                                                            executing completed]).sum(:amount_minor)
      invoice.total_minor - reserved
    end

    def provider_recording(invoice)
      invoice.financial_command&.provider_account_recording || raise(ArgumentError,
                                                                     "invoice has no provider authority")
    end

    def provider_adapter_key(invoice)
      invoice.financial_command&.provider_adapter_key || raise(ArgumentError,
                                                               "invoice has no provider authority")
    end

    def trusted_manual_authority!(invoice)
      raise ArgumentError, "adjustments require an actor" if actor_reference.blank?

      authorizer = RecordingStudioBilling.configuration.commercial_authorizer
      authorized = authorizer&.call(action: :adjustment, actor_reference:, root_recording: invoice.root_recording,
                                    account_recording: invoice.account_recording, invoice:, affected_reference:)
      raise ArgumentError, "adjustment is not host-authorized" unless authorized == true

      { "source" => "host_authorizer", "actor_reference" => actor_reference,
        "affected_reference" => SafeFinancialPayload.normalize(affected_reference) }
    end
  end
end
