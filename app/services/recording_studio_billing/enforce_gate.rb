# frozen_string_literal: true

module RecordingStudioBilling
  class EnforceGate
    # Plan feature values of -1 mean unlimited for limit gates.
    UNLIMITED = -1

    class Denied < StandardError
      attr_reader :gate_key, :reason, :current, :limit, :remaining, :code, :quantity

      def initialize(gate_key:, reason:, code:, current: nil, limit: nil, remaining: nil, quantity: nil)
        @gate_key = gate_key
        @reason = reason
        @code = code
        @current = current
        @limit = limit
        @remaining = remaining
        @quantity = quantity
        super(reason)
      end
    end

    Result = Data.define(:allowed, :gate_key, :reason, :current, :limit, :remaining, :code, :quantity)

    def self.call(...) = new(...).call

    def initialize(root_recording:, gate_key:, subject: nil, quantity: 1, raise_on_failure: false)
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @gate_key = gate_key.to_s
      @subject = subject
      @quantity = Integer(quantity)
      raise ArgumentError, "gate quantity must be greater than 0" unless @quantity.positive?

      @raise_on_failure = raise_on_failure == true
    end

    def call
      gate = GateRegistry.fetch!(gate_key)
      result = evaluate(gate)
      if raise_on_failure && !result.allowed
        raise Denied.new(
          gate_key:, reason: result.reason, code: result.code, current: result.current,
          limit: result.limit, remaining: result.remaining, quantity: result.quantity
        )
      end

      result
    end

    private

    attr_reader :gate_key, :quantity, :raise_on_failure, :root_recording, :subject

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
      feature_key = gate.fetch("feature_key", gate_key)
      limit = RecordingStudioBilling.feature_value(root_recording:, feature_key:)
      return denied("no #{gate_label(gate)} allowance is configured", code: "not_configured") if limit.nil?

      limit = Integer(limit)
      current = Integer(current_count(gate))
      if unlimited?(limit)
        return Result.new(allowed: true, gate_key:, reason: nil, current:, limit:, remaining: nil, code: nil,
                          quantity:)
      end

      remaining = [limit - current, 0].max
      allowed = current + quantity <= limit
      reason = allowed ? nil : "#{gate_label(gate)} limit reached (#{current}/#{limit})"
      code = allowed ? nil : "limit_reached"
      Result.new(allowed:, gate_key:, reason:, current:, limit:, remaining:, code:, quantity:)
    rescue ArgumentError, TypeError => e
      raise if e.message.start_with?("gate ") || e.message.include?("subject is required")

      raise ArgumentError, "gate count must return an integer"
    end

    def current_count(gate)
      count = gate.fetch("count")
      raise ArgumentError, "gate #{gate_key} requires subject" if gate.fetch("requires_subject", false) && subject.nil?

      if gate.fetch("accepts_subject", false) && !subject.nil?
        count.call(root: root_recording, subject:)
      else
        count.call(root: root_recording)
      end
    end

    def evaluate_boolean(gate)
      feature_key = gate.fetch("feature_key")
      allowed = RecordingStudioBilling.entitled?(root_recording:, feature_key:)
      reason = allowed ? nil : "#{gate_label(gate)} is not included in your plan"
      code = allowed ? nil : "not_entitled"
      Result.new(allowed:, gate_key:, reason:, current: nil, limit: nil, remaining: nil, code:, quantity: nil)
    end

    def denied(reason, code:)
      Result.new(allowed: false, gate_key:, reason:, current: nil, limit: nil, remaining: nil, code:, quantity:)
    end

    def unlimited?(limit)
      limit == UNLIMITED
    end

    def gate_label(gate)
      gate.fetch("label", gate_key).presence || gate_key
    end
  end
end
