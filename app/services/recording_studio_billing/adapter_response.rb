# frozen_string_literal: true

module RecordingStudioBilling
  class AdapterResponse
    STATUSES = %w[
      success duplicate invalid unauthorized unsupported unsupported_tax_calculation
      unsupported_checkout_mode unsupported_checkout_composition unsupported_subscription_composition
      unsupported_market unsupported_currency charge_market_verification_unavailable conflict
      provider_unavailable provider_rejected pending stale rate_missing rate_ambiguous
      requires_review failed unknown
    ].freeze

    attr_reader :status, :provider_reference, :result, :error_details, :metadata, :uncertain_outcome

    def initialize(status:, provider_reference: nil, result: {}, error_details: {}, metadata: {}, uncertain_outcome: false,
             allow_authoritative_totals: false)
      normalized_status = status.to_s
      @status = STATUSES.include?(normalized_status) ? normalized_status : "unknown"
      @provider_reference = normalize_reference(provider_reference)
      @result = SafeFinancialPayload.normalize(result, allow_authoritative_totals:)
                .merge("status" => @status).freeze
      @error_details = SafeFinancialPayload.normalize(error_details).freeze
      @metadata = SafeFinancialPayload.normalize(metadata).freeze
      @uncertain_outcome = uncertain_outcome == true || @status == "unknown"
      freeze
    end

    private

    def normalize_reference(value)
      return if value.nil?

      SafeFinancialPayload.normalize_reference(value, label: "provider reference")
    end
  end
end