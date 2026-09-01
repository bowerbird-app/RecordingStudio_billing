# frozen_string_literal: true

module RecordingStudioBilling
  class CreateRefundIntent
    Result = Data.define(:status, :intent) do
      def created? = status == :created
      def existing? = status == :existing
      def conflict? = status == :conflict
    end

    def self.call(...) = new(...).call

    def initialize(payment:, root_recording:, local_idempotency_key:, amount_minor:, metadata: {}, reason: nil,
                   actor_reference: nil, tax_treatment: "provider_default", reversal_policy: "none", line_allocation: {})
      @payment_input = payment
      @root_recording_input = root_recording
      @local_idempotency_key = local_idempotency_key.to_s
      @amount_minor = amount_minor
      @metadata = metadata
      @reason = reason
      @actor_reference = actor_reference
      @tax_treatment = tax_treatment
      @reversal_policy = reversal_policy
      @line_allocation = line_allocation
    end

    def call
      RefundIntent.transaction do
        payment = Payment.where(root_recording: RecordingStudio.root_recording_or_self(root_recording_input)).lock.find(payment_id)
        validate_payment!(payment)
        manual_authority!(payment)
        validate_request_payloads!
        fingerprint = CommercialManifestCanonicalizer.digest("payment_id" => payment.id, "amount_minor" => amount_minor,
                                                             "currency" => payment.currency_code, "reason" => reason,
                                                             "tax_treatment" => tax_treatment, "reversal_policy" => reversal_policy,
                                                             "line_allocation" => line_allocation, "actor_reference" => actor_reference,
                                                             "metadata" => SafeFinancialPayload.normalize(metadata))
        existing = RefundIntent.lock.find_by(root_recording: payment.root_recording, local_idempotency_key:)
        if existing
          return Result.new(status: existing.request_fingerprint == fingerprint ? :existing : :conflict,
                            intent: existing)
        end
        if amount_minor.to_i <= 0 || amount_minor.to_i > refundable_amount(payment)
          raise ArgumentError,
                "refund amount exceeds paid payment"
        end

        intent = RefundIntent.create!(payment:, root_recording: payment.root_recording, account_recording: payment.account_recording,
                                      provider_account_recording_id: payment.financial_command.provider_account_recording_id,
                                      local_idempotency_key:, request_fingerprint: fingerprint, amount_minor:, currency_code: payment.currency_code,
                                      reason:, actor_reference:, tax_treatment:, reversal_policy:, line_allocation:, safe_metadata: metadata)
        command = CreateFinancialCommand.call(
          root_recording: payment.root_recording, account_recording: payment.account_recording, command_type: "refund",
          local_idempotency_key: "refund:#{intent.id}", provider_account_recording: payment.financial_command.provider_account_recording,
          provider_adapter_key: payment.financial_command.provider_adapter_key,
          request: { refund_intent_id: intent.id, payment_id: payment.id, provider_payment_reference: payment.provider_reference,
                     amount_minor:, currency: payment.currency_code,
                     reason:, actor_reference:, tax_treatment:, reversal_policy:, line_allocation:,
                     request_fingerprint: fingerprint }
        ).command
        intent.update!(financial_command: command)
        Result.new(status: :created, intent:)
      end
    end

    private

    attr_reader :actor_reference, :amount_minor, :line_allocation, :local_idempotency_key, :metadata, :payment_input, :reason,
                :reversal_policy, :root_recording_input, :tax_treatment

    def payment_id = payment_input.respond_to?(:id) ? payment_input.id : payment_input

    def validate_payment!(payment)
      raise ArgumentError, "refund payment is not paid" unless payment.state == "paid"
      raise ArgumentError, "refund payment currency is invalid" unless payment.currency_code.match?(/\A[A-Z]{3}\z/)

      return if payment.financial_command&.provider_account_recording_id.present?

      raise ArgumentError,
            "refund payment has no provider authority"
    end

    def manual_authority!(payment)
      raise ArgumentError, "refund requires an actor" if actor_reference.blank?

      authorizer = RecordingStudioBilling.configuration.commercial_authorizer
      authorized = authorizer&.call(action: :refund, actor_reference:, root_recording: payment.root_recording,
                                    account_recording: payment.account_recording, payment:, line_allocation:)
      raise ArgumentError, "refund is not host-authorized" unless authorized == true
    end

    def validate_request_payloads!
      validate_text!(:reason, reason, required: true)
      validate_text!(:tax_treatment, tax_treatment, required: true)
      validate_text!(:reversal_policy, reversal_policy, required: true)
      validate_text!(:actor_reference, actor_reference, required: true)
      validate_payload!(:line_allocation, line_allocation)
      validate_payload!(:metadata, metadata)
    end

    def validate_text!(name, value, required: false)
      string = value.to_s
      raise ArgumentError, "refund #{name} is required" if required && string.empty?
      raise ArgumentError, "refund #{name} is too long" if string.length > 512
    end

    def validate_payload!(name, value)
      normalized = SafeFinancialPayload.normalize(value)
      unless normalized.is_a?(Hash) || normalized.is_a?(Array)
        raise ArgumentError,
              "refund #{name} must be a structured value"
      end
      raise ArgumentError, "refund #{name} is too large" if normalized.to_json.bytesize > 16_384
    rescue SafeFinancialPayload::UnsafeValue
      raise ArgumentError, "refund #{name} is invalid"
    end

    def refundable_amount(payment)
      reserved = payment.refund_intents.where(state: %w[pending executing completed]).sum(:amount_minor)
      payment.amount_minor - reserved
    end
  end
end
