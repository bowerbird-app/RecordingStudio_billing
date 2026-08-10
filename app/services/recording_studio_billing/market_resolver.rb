# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Lint/MissingCopEnableDirective

module RecordingStudioBilling
  class MarketResolver
    Resolution = Data.define(:market, :currency_code, :country_code, :stage, :source, :outcome, :previous_market)
    SOURCES = %i[verified_account provider host declaration ip default].freeze
    STAGES = %i[display provisional_charge final_charge].freeze

    def initialize(markets:, configuration: RecordingStudioBilling.configuration)
      @markets = Array(markets)
      @configuration = configuration
    end

    # All values passed here must come from the host's trusted identity/location
    # adapters. Request parameters are deliberately not accepted by this API.
    def resolve(stage:, account_country: nil, provider_country: nil, host_country: nil,
                declaration_country: nil, ip_country: nil, explicit_currency: nil,
                account_currency: nil, billing_option_currency: nil, previous: nil)
      stage = stage.to_sym
      raise ArgumentError, "unsupported market resolution stage" unless STAGES.include?(stage)

      country, source = select_country(
        stage, account_country, provider_country, host_country, declaration_country, ip_country
      )
      market = select_market(country)
      currency = select_currency(market, explicit_currency, account_currency, billing_option_currency)
      outcome = final_outcome(stage, previous, market, currency)
      Resolution.new(market, currency, country, stage, source, outcome, previous&.market)
    end

    private

    attr_reader :markets, :configuration

    def select_country(stage, account, provider, host, declaration, ip)
      values = {
        verified_account: account,
        provider: provider,
        host: host,
        declaration: declaration,
        ip: ip,
        default: configuration.market_default_country
      }
      values.delete(:verified_account) unless stage == :final_charge || valid_country?(account)
      source, country = SOURCES.filter_map do |key|
        [key, normalize_country(values[key])] if valid_country?(values[key])
      end.first
      raise ArgumentError, "no trusted country is available for market resolution" unless country

      [country, source]
    end

    def select_market(country)
      matches = markets.filter_map do |market|
        next unless eligible?(market)

        market_score = score(market, country)
        [market, market_score] if market_score
      end
      raise ArgumentError, "no eligible market for #{country}" if matches.empty?

      highest_score = matches.map(&:last).max
      winners = matches.select { |(_, score_value)| score_value == highest_score }.map(&:first)
      raise ArgumentError, "ambiguous market resolution for #{country}" if winners.many?

      winners.first
    end

    def score(market, country)
      return [3, market.specificity, market.priority] if Array(market.country_codes).include?(country)

      group_sizes = market.country_groups.to_h.values.filter_map do |countries|
        Array(countries).include?(country) ? Array(countries).size : nil
      end
      return [2, market.specificity, -group_sizes.min, market.priority] if group_sizes.any?
      return [1, market.specificity, market.priority] if market.fallback?

      nil
    end

    def select_currency(market, explicit, account, billing_option)
      permitted = Array(market.allowed_currency_codes)
      if explicit.present? && !permitted.include?(explicit.to_s.upcase)
        raise ArgumentError, "explicit currency is not permitted by market #{market.key}"
      end

      [explicit, account, market.default_currency_code,
       billing_option].compact.map(&:to_s).map(&:upcase).find do |currency|
        permitted.include?(currency)
      end || raise(ArgumentError, "no permitted currency for market #{market.key}")
    end

    def final_outcome(stage, previous, market, currency)
      return :resolved unless stage == :final_charge && previous
      return :confirmed if previous.market == market && previous.currency_code == currency

      %w[reject review restart].include?(market.verification_policy) ? market.verification_policy.to_sym : :requote
    end

    def eligible?(market)
      return false unless market.respond_to?(:state) && market.state == "published"

      provider = market.provider_account_recording&.recordable
      provider.is_a?(ProviderAccount) && provider.state == "published" && provider.active?
    end

    def valid_country?(value)
      normalize_country(value)&.match?(/\A[A-Z]{2}\z/)
    end

    def normalize_country(value)
      value&.to_s&.upcase
    end
  end
end
