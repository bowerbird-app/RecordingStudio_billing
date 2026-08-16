# frozen_string_literal: true

module RecordingStudioBilling
  class FakeFinancialAdapter
    class InvalidRequest < ArgumentError; end
    class TimeoutAfterPossibleSuccess < StandardError; end

    OUTCOMES = (AdapterResponse::STATUSES.map(&:to_sym) + %i[
      invalid_request provider_rejection timeout_after_possible_success unknown_provider_state
    ]).uniq.freeze

    attr_reader :calls, :idempotency_keys, :transaction_open_during_calls, :capabilities

    def initialize(outcome:, capabilities: nil)
      raise ArgumentError, "unsupported fake adapter outcome" unless OUTCOMES.include?(outcome)

      @outcome = outcome
      @capabilities = capabilities || V1Contract.provider_capabilities(
        operations: %w[checkout subscription_change refund adjustment collect_usage usage_settlement usage_correction],
        tax_modes: %w[external provider],
        usage_settlement_representations: %w[invoice_line]
      )
      @calls = 0
      @idempotency_keys = []
      @transaction_open_during_calls = []
      @provider_effects = {}
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
        @transaction_open_during_calls << ActiveRecord::Base.connection.transaction_open?
      end
      raise ArgumentError, "adapter received a noncanonical request" unless request == command.canonical_request

      return duplicate_response_for(idempotency_key) if @provider_effects.key?(idempotency_key)

      if outcome == :timeout_after_possible_success
        @provider_effects[idempotency_key] = "fake-operation"
        raise TimeoutAfterPossibleSuccess, "provider outcome is uncertain"
      end

      response = response_for(outcome)
      @provider_effects[idempotency_key] = response.provider_reference if %w[success duplicate].include?(response.status)
      response
    end

    def provider_reference_type(command:, provider_reference:)
      "operation" if provider_reference.present? && command.command_type.present?
    end

    private

    attr_reader :outcome

    def response_for(value)
      case value
      when :success
        response("success", provider_reference: "fake-operation")
      when :duplicate
        response("duplicate", provider_reference: "fake-existing-operation")
      when :provider_rejection
        response("provider_rejected", error: { "category" => "provider_rejected" })
      when :unknown_provider_state
        response("provider_specific_state", outcome_name: "unknown_provider_state")
      else
        response(value.to_s)
      end
    end

    def duplicate_response_for(idempotency_key)
      response("duplicate", provider_reference: @provider_effects.fetch(idempotency_key), outcome_name: "duplicate")
    end

    def response(status, provider_reference: nil, error: {}, outcome_name: status)
      AdapterResponse.new(
        status:,
        provider_reference:,
        result: { "outcome" => outcome_name },
        error_details: error,
        metadata: { "adapter" => "fake" }
      )
    end
  end
end
