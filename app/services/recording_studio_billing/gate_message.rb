# frozen_string_literal: true

module RecordingStudioBilling
  class GateMessage
    DEFAULTS = {
      "limit_reached" => "%{label} limit reached (%{current}/%{limit}). Pick a bigger plan to add more.",
      "not_configured" => "%{label} is not on this plan yet. Choose a plan that includes it.",
      "not_entitled" => "%{label} is not included in your plan. Upgrade to unlock it."
    }.freeze

    def self.call(...) = new(...).call

    def initialize(result)
      @result = result
    end

    def call
      return nil if allowed?
      return nil if result.code.blank?

      template = copy_for(result.code)
      format(
        template,
        label: label,
        current: result.current,
        limit: result.limit,
        remaining: result.remaining,
        quantity: result.quantity
      )
    end

    private

    attr_reader :result

    def allowed?
      result.respond_to?(:allowed) && result.allowed
    end

    def label
      gate = RecordingStudioBilling.configuration.gates[result.gate_key]
      gate&.fetch("label", result.gate_key).presence || result.gate_key.to_s.tr("_", " ")
    end

    def copy_for(code)
      key = "gate_#{code}"
      RecordingStudioBilling.configuration.billing_copy.fetch(key, DEFAULTS.fetch(code, result.reason))
    end
  end
end
