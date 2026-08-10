# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Lint/MissingCopEnableDirective

require "digest"
require "json"
require "bigdecimal"

module RecordingStudioBilling
  class CommercialManifestCanonicalizer
    class UnsupportedValue < ArgumentError; end
    MAX_DEPTH = 32
    MAX_NODES = 10_000
    MAX_COLLECTION_SIZE = 1_000
    MAX_STRING_BYTES = 65_536
    RESERVED_WRAPPER_KEYS = %w[__decimal__ __time__ __date__].freeze

    class << self
      def canonicalize(value)
        normalized = normalize(value, depth: 0, node_count: [0])
        JSON.generate(normalized).tap do |json|
          raise UnsupportedValue, "commercial manifest is too large" if json.bytesize > MAX_STRING_BYTES
        end
      end

      def digest(value)
        Digest::SHA256.hexdigest(canonicalize(value))
      end

      private

      def normalize(value, depth:, node_count:)
        raise UnsupportedValue, "commercial manifest is too deeply nested" if depth > MAX_DEPTH

        node_count[0] += 1
        raise UnsupportedValue, "commercial manifest has too many values" if node_count[0] > MAX_NODES

        case value
        when Hash
          value.each_with_object({}) do |(key, nested), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise UnsupportedValue,
                    "manifest keys must be strings or symbols"
            end

            normalized_key = key.to_s
            raise UnsupportedValue, "manifest contains a reserved wrapper key" if RESERVED_WRAPPER_KEYS.include?(normalized_key)
            raise UnsupportedValue, "manifest contains duplicate canonical keys" if result.key?(normalized_key)

            result[normalized_key] = normalize(nested, depth: depth + 1, node_count:)
          end.sort.to_h
        when Array
          raise UnsupportedValue, "manifest collection is too large" if value.size > MAX_COLLECTION_SIZE

          value.map { |nested| normalize(nested, depth: depth + 1, node_count:) }
        when String
          raise UnsupportedValue, "manifest string is too large" if value.bytesize > MAX_STRING_BYTES

          value
        when TrueClass, FalseClass, NilClass, Integer then value
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
