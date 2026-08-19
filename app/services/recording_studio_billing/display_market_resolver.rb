# frozen_string_literal: true

module RecordingStudioBilling
  class DisplayMarketResolver
    def self.call(...) = new(...).call

    def initialize(product:, root_recording:, account_recording:, location_context: nil)
      @product = product
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @account_recording = account_recording
      @location_context = location_context || default_location_context
    end

    def call
      MarketResolver.new(markets:, configuration: RecordingStudioBilling.configuration).resolve(
        stage: :display, account_country: context[:verified_account_country], provider_country: context[:provider_country],
        host_country: context[:host_country], declaration_country: context[:declaration_country], ip_country: context[:ip_country],
        account_currency: context[:account_currency]
      )
    rescue ArgumentError => e
      raise unless e.message.start_with?("no trusted country is available", "no eligible market")

      global_fallback
    end

    private

    attr_reader :account_recording, :location_context, :product, :root_recording

    def markets
      Market.with_current_recording.where(provider_account_recording_id: product.provider_account_recording_id,
                                          state: "published")
    end

    def context = location_context.to_h.symbolize_keys

    def default_location_context
      if account_recording.present?
        account = account_recording.recordable
        host = RecordingStudioBilling.configuration.billing_location_context_resolver&.call(root_recording:,
                                                                                            account_recording:).to_h || {}
        host.symbolize_keys.merge(declaration_country: account.billing_country_code,
                                  account_currency: account.billing_currency_code)
      else
        (RecordingStudioBilling.configuration.billing_location_context_resolver&.call(root_recording:)&.to_h || {}).symbolize_keys
      end
    end

    def global_fallback
      candidates = markets.select(&:global_fallback?).select do |market|
        market.provider_account_recording.recordable&.active?
      end
      highest_score = candidates.map { |market| [market.specificity, market.priority] }.max
      winners = candidates.select { |market| highest_score == [market.specificity, market.priority] }
      raise ArgumentError, "global market fallback is unavailable or ambiguous" unless winners.one?

      market = winners.first
      currency = [context[:account_currency], market.default_currency_code,
                  *market.allowed_currency_codes].compact.map(&:upcase).find do |value|
        market.allowed_currency_codes.include?(value)
      end
      raise ArgumentError, "global market has no available currency" unless currency

      MarketResolver::Resolution.new(market, currency, nil, :display, :global_fallback, :resolved, nil)
    end
  end
end
