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
      @capabilities = capabilities || ProviderCapabilities.new(
        operations: %w[charge checkout subscription subscription_change refund adjustment tax],
        currencies: %w[EUR GBP USD], markets: %w[CA GB US],
        collection_methods: %w[automatic manual], checkout_modes: %w[payment setup subscription],
        tax_modes: %w[external provider], quantities: %w[fixed adjustable],
        composition: %w[single mixed], refunds: %w[full partial], adjustments: %w[credit debit],
        subscription_change_kinds: %w[plan interval addon quantity cancellation resumption]
      )
      @calls = 0
      @idempotency_keys = []
      @transaction_open_during_calls = []
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
      raise TimeoutAfterPossibleSuccess, "provider outcome is uncertain" if outcome == :timeout_after_possible_success

      response_for(outcome)
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
