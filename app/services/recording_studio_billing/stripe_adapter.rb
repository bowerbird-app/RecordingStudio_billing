# frozen_string_literal: true

module RecordingStudioBilling
  class StripeAdapter
    CAPABILITIES = ProviderCapabilities.new.freeze

    attr_reader :capabilities

    def initialize(credential_resolver: nil)
      if !credential_resolver.nil? && !credential_resolver.respond_to?(:call)
        raise ArgumentError, "stripe credential resolver must respond to call"
      end

      @credential_resolver = credential_resolver
      @capabilities = CAPABILITIES
    end

    def call(command: _, request: _, idempotency_key: _)
      return unavailable_response("configuration_missing") if credential_resolver.nil? || credential_resolver.call.nil?

      unsupported_response
    end

    private

    attr_reader :credential_resolver

    def unavailable_response(reason)
      AdapterResponse.new(
        status: "provider_unavailable",
        result: { "reason" => reason },
        error_details: { "category" => "provider_unavailable" },
        metadata: { "adapter" => "stripe" }
      )
    end

    def unsupported_response
      AdapterResponse.new(
        status: "unsupported",
        result: { "reason" => "operation_not_implemented" },
        error_details: { "category" => "unsupported" },
        metadata: { "adapter" => "stripe" }
      )
    end
  end
end