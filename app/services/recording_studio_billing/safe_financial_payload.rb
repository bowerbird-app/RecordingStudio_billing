# frozen_string_literal: true

module RecordingStudioBilling
  class SafeFinancialPayload
    class UnsafeValue < ArgumentError; end

    SENSITIVE_KEY = /authorization|credential|password|secret|token|api[_-]?key|private[_-]?key|signature/i
    PAYMENT_CREDENTIAL_KEY = /card[_-]?(number|cvc|cvv)|payment[_-]?(nonce|credential)|bank[_-]?account|routing[_-]?number|\Apan\z/i
    UNSAFE_PROVIDER_KEY = /provider[_-]?(url|uri|id|identifier|account[_-]?id|customer[_-]?id|response|payload|body)|raw[_-]?(provider|response|payload|body)/i
    UNTRUSTED_TOTAL_KEY = /\A(?!(?:approved|authorized)_)(?:client[_-]?)?(?:grand[_-]?)?(?:sub)?total(?:_amount)?(?:_minor)?\z/i

    class << self
      def normalize(value)
        normalized = JSON.parse(CommercialManifestCanonicalizer.canonicalize(value))
        raise UnsafeValue, "must be an object" unless normalized.is_a?(Hash)

        reject_sensitive_keys!(normalized)
        normalized
      rescue CommercialManifestCanonicalizer::UnsupportedValue => e
        raise UnsafeValue, e.message
      end

      def validate!(value)
        normalize(value)
        true
      end

      private

      def reject_sensitive_keys!(value)
        case value
        when Hash
          value.each do |key, nested|
            if [SENSITIVE_KEY, PAYMENT_CREDENTIAL_KEY, UNSAFE_PROVIDER_KEY].any? { |pattern| key.match?(pattern) }
              raise UnsafeValue, "must not contain credentials, signatures, or raw provider data"
            end
            if key.match?(UNTRUSTED_TOTAL_KEY)
              raise UnsafeValue, "must not contain untrusted financial totals"
            end

            reject_sensitive_keys!(nested)
          end
        when Array
          value.each { |nested| reject_sensitive_keys!(nested) }
        end
      end
    end
  end
end