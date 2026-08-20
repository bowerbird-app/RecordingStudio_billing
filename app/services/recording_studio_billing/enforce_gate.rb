# frozen_string_literal: true

module RecordingStudioBilling
  class EnforceGate
    class Denied < StandardError
      attr_reader :gate_key, :reason, :current, :limit

      def initialize(gate_key:, reason:, current: nil, limit: nil)
        @gate_key = gate_key
        @reason = reason
        @current = current
        @limit = limit
        super(reason)
      end
    end

    Result = Data.define(:allowed, :gate_key, :reason, :current, :limit)

    def self.call(...) = new(...).call

    def initialize(root_recording:, gate_key:, raise_on_failure: false)
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @gate_key = gate_key.to_s
      @raise_on_failure = raise_on_failure == true
    end

    def call
      gate = GateRegistry.fetch!(gate_key)
      result = evaluate(gate)
      raise Denied.new(gate_key:, reason: result.reason, current: result.current, limit: result.limit) if raise_on_failure && !result.allowed

      result
    end

    private

    attr_reader :gate_key, :raise_on_failure, :root_recording

    def evaluate(gate)
      case gate.fetch("kind")
      when "limit"
        evaluate_limit(gate)
      when "boolean"
        evaluate_boolean(gate)
      else
        raise ArgumentError, "unsupported gate kind"
      end
    end

    def evaluate_limit(gate)
      limit = RecordingStudioBilling.feature_value(root_recording:, feature_key: gate_key)
      return denied("no #{gate_label(gate)} allowance is configured") if limit.nil?

      current = Integer(gate.fetch("count").call(root: root_recording))
      allowed = current < limit
      reason = allowed ? nil : "#{gate_label(gate)} limit reached (#{current}/#{limit})"
      Result.new(allowed:, gate_key:, reason:, current:, limit:)
    rescue ArgumentError, TypeError
      raise ArgumentError, "gate count must return an integer"
    end

    def evaluate_boolean(gate)
      feature_key = gate.fetch("feature_key")
      allowed = RecordingStudioBilling.entitled?(root_recording:, feature_key:)
      reason = allowed ? nil : "#{gate_label(gate)} is not included in your plan"
      Result.new(allowed:, gate_key:, reason:, current: nil, limit: nil)
    end

    def denied(reason)
      Result.new(allowed: false, gate_key:, reason:, current: nil, limit: nil)
    end

    def gate_label(gate)
      gate.fetch("label", gate_key).presence || gate_key
    end
  end
end
