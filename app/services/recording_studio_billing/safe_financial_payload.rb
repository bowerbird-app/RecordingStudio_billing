# frozen_string_literal: true

module RecordingStudioBilling
  class SafeFinancialPayload
    class UnsafeValue < ArgumentError; end

    SENSITIVE_KEY = /authorization|credential|password|secret|token|api[_-]?key|private[_-]?key|signature/i
    PAYMENT_CREDENTIAL_KEY = /card[_-]?(number|cvc|cvv)|payment[_-]?(nonce|credential)|bank[_-]?account|routing[_-]?number|\Apan\z/i
    UNSAFE_PROVIDER_KEY = /provider[_-]?(url|uri|id|identifier|account[_-]?id|customer[_-]?id|response|payload|body)|raw[_-]?(provider|response|payload|body)/i
    TAX_PII_KEY = /(?:\A|[_-])(?:tax|vat)[_-]?(?:id|identifier|number)\z|(?:\A|[_-])(?:email|phone|address|postal[_-]?code|ip[_-]?address)\z/i
    URL_KEY = /(?:\A|[_-])(?:url|uri)\z/i
    URL_VALUE = /\A\s*(?:https?|ftp):\/\//i
    UNTRUSTED_TOTAL_KEY = /\A(?!(?:approved|authorized)_)(?:client[_-]?)?(?:grand[_-]?)?(?:sub)?total(?:_amount)?(?:_minor)?\z/i

    class << self
      def normalize(value, allow_authoritative_totals: false)
        normalized = JSON.parse(CommercialManifestCanonicalizer.canonicalize(value))
        raise UnsafeValue, "must be an object" unless normalized.is_a?(Hash)

        reject_sensitive_keys!(normalized, allow_authoritative_totals:)
        normalized
      rescue CommercialManifestCanonicalizer::UnsupportedValue => e
        raise UnsafeValue, e.message
      end

      def validate!(value, allow_authoritative_totals: false)
        normalize(value, allow_authoritative_totals:)
        true
      end

      def normalize_reference(value, label: "reference", maximum: 512)
        unless value.is_a?(String) && value.bytesize.between?(1, maximum) &&
               value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/) && !value.match?(URL_VALUE)
          raise UnsafeValue, "#{label} must be a bounded opaque reference"
        end

        value
      end

      private

      def reject_sensitive_keys!(value, allow_authoritative_totals:)
        case value
        when Hash
          value.each do |key, nested|
            if [SENSITIVE_KEY, PAYMENT_CREDENTIAL_KEY, UNSAFE_PROVIDER_KEY, TAX_PII_KEY, URL_KEY].any? { |pattern| key.match?(pattern) }
              raise UnsafeValue, "must not contain credentials, signatures, or raw provider data"
            end
            if !allow_authoritative_totals && key.match?(UNTRUSTED_TOTAL_KEY)
              raise UnsafeValue, "must not contain untrusted financial totals"
            end

            reject_sensitive_keys!(nested, allow_authoritative_totals:)
          end
        when Array
          value.each { |nested| reject_sensitive_keys!(nested, allow_authoritative_totals:) }
        when String
          raise UnsafeValue, "must not contain URLs" if value.match?(URL_VALUE)
        end
      end
    end
  end
end