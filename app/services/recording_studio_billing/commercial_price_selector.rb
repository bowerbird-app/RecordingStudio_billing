# frozen_string_literal: true

module RecordingStudioBilling
  class CommercialPriceSelector
    def initialize(billing_option:, market:, currency_code:, scope: "default")
      @billing_option = billing_option
      @market = market
      @currency_code = currency_code
      @scope = scope
    end

    def price!
      Price.with_current_recording.where(
        billing_option_recording_id: billing_option.recording.id,
        market_recording_id: market.recording.id,
        currency_code: currency_code,
        scope: scope,
        state: "published"
      ).sole
    rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded
      raise ArgumentError, "exactly one published price is required for the selected market and currency"
    end

    private

    attr_reader :billing_option, :market, :currency_code, :scope
  end
end
