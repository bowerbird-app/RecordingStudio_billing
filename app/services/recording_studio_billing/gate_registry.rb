# frozen_string_literal: true

module RecordingStudioBilling
  class GateRegistry
    KINDS = %w[limit boolean].freeze

    class << self
      def fetch!(key)
        configuration.fetch(key.to_s) { raise KeyError, "unknown gate: #{key}" }
      end

      def normalize(value)
        gate = value.respond_to?(:to_h) ? value.to_h.transform_keys(&:to_sym) : {}
        kind = gate.fetch(:kind).to_s
        raise ArgumentError, "unsupported gate kind" unless KINDS.include?(kind)

        normalized = { "kind" => kind }
        normalized["label"] = gate[:label].to_s if gate[:label].present?
        feature_key = gate[:feature_key].presence || gate[:key].presence
        normalized["feature_key"] = feature_key.to_s if feature_key.present?

        case kind
        when "limit"
          count = gate.fetch(:count)
          raise ArgumentError, "limit gate count must respond to call" unless count.respond_to?(:call)

          normalized["count"] = count
          normalized["accepts_subject"] = accepts_keyword?(count, :subject)
          normalized["requires_subject"] = requires_keyword?(count, :subject)
        when "boolean"
          raise ArgumentError, "boolean gate requires feature_key" if normalized["feature_key"].blank?
        end

        normalized.freeze
      end

      def accepts_keyword?(callable, keyword)
        parameters = callable.parameters
        return true if parameters.any? { |type, _| type == :keyrest }

        parameters.any? { |type, name| name == keyword && %i[key keyreq].include?(type) }
      end

      def requires_keyword?(callable, keyword)
        callable.parameters.any? { |type, name| name == keyword && type == :keyreq }
      end

      private

      def configuration
        RecordingStudioBilling.configuration.gates
      end
    end
  end
end
