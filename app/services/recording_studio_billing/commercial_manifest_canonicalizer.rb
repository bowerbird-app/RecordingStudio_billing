# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Lint/MissingCopEnableDirective

require "digest"
require "json"
require "bigdecimal"

module RecordingStudioBilling
  class CommercialManifestCanonicalizer
    class UnsupportedValue < ArgumentError; end

    class << self
      def canonicalize(value)
        JSON.generate(normalize(value))
      end

      def digest(value)
        Digest::SHA256.hexdigest(canonicalize(value))
      end

      private

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise UnsupportedValue,
                    "manifest keys must be strings or symbols"
            end

            result[key.to_s] = normalize(nested)
          end.sort.to_h
        when Array then value.map { |nested| normalize(nested) }
        when String, TrueClass, FalseClass, NilClass, Integer then value
        when BigDecimal then { "__decimal__" => value.to_s("F") }
        when Time, DateTime then { "__time__" => value.utc.iso8601(6) }
        when Date then { "__date__" => value.iso8601 }
        when Float then raise UnsupportedValue, "floats are not supported in commercial manifests"
        else
          raise UnsupportedValue, "unsupported commercial manifest value: #{value.class}"
        end
      end
    end
  end
end
