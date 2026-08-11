# frozen_string_literal: true

module RecordingStudioBilling
  class FakeFinancialAdapter
    class InvalidRequest < ArgumentError; end
    class TimeoutAfterPossibleSuccess < StandardError; end

    OUTCOMES = %i[
      success duplicate invalid_request provider_rejection provider_unavailable
      timeout_after_possible_success pending unknown_provider_state
    ].freeze

    attr_reader :calls, :idempotency_keys

    def initialize(outcome:)
      raise ArgumentError, "unsupported fake adapter outcome" unless OUTCOMES.include?(outcome)

      @outcome = outcome
      @calls = 0
      @idempotency_keys = []
      @mutex = Mutex.new
    end

    def validate!(request:)
      raise InvalidRequest, "request rejected before persistence" if outcome == :invalid_request
      raise InvalidRequest, "request must be an object" unless request.is_a?(Hash)
    end

    def call(command:, request:, idempotency_key:)
      @mutex.synchronize do
        @calls += 1
        @idempotency_keys << idempotency_key
      end
      raise ArgumentError, "adapter received a noncanonical request" unless request == command.canonical_request
      raise TimeoutAfterPossibleSuccess, "provider outcome is uncertain" if outcome == :timeout_after_possible_success

      response_for(outcome)
    end

    private

    attr_reader :outcome

    def response_for(value)
      case value
      when :success
        response("succeeded", "success", provider_reference: "fake-operation")
      when :duplicate
        response("succeeded", "duplicate", provider_reference: "fake-existing-operation")
      when :provider_rejection
        response("failed", "provider_rejection", error: { "category" => "provider_rejection" })
      when :provider_unavailable
        response("failed", "provider_unavailable", error: { "category" => "provider_unavailable", "retryable" => true })
      when :pending
        response("pending", "pending", provider_reference: "fake-pending-operation")
      when :unknown_provider_state
        response("provider_specific_state", "unknown_provider_state", provider_reference: "fake-unknown-operation")
      end
    end

    def response(state, outcome_name, provider_reference: nil, error: {})
      {
        state:,
        provider_reference:,
        normalized_result: { "outcome" => outcome_name },
        safe_error_details: error,
        safe_metadata: { "adapter" => "fake" }
      }
    end
  end
end