# frozen_string_literal: true

module RecordingStudioBilling
  class CreateRatedUsageSettlement
    Result = Data.define(:status, :settlement, :command, :reason) do
      def created? = status == :created
      def existing? = status == :existing
      def conflict? = status == :conflict
      def unsupported? = status == :unsupported
      def requires_review? = status == :requires_review
      def denied? = status == :denied
    end

    def self.call(...) = new(...).call

    def initialize(root_recording:, rated_usage:, metadata: {})
      @root_recording_input = root_recording
      @rated_usage_input = rated_usage
      @metadata = metadata
    end

    def call
      root, account = authority!
      rated_usage = authoritative_rated_usage(root, account)
      terms = settlement_terms(rated_usage)
      return Result.new(status: terms, settlement: nil, command: nil, reason: terms) if terms.is_a?(Symbol)

      capability = provider_capability(terms, rated_usage)
      return Result.new(status: :unsupported, settlement: nil, command: nil, reason: capability.reason) unless capability.supported?

      request = canonical_request(rated_usage, terms)
      RatedUsageSettlement.transaction(requires_new: true) do
        existing = RatedUsageSettlement.lock.find_by(rated_usage:)
        return existing_result(existing, request) if existing

        command_result = CreateFinancialCommand.call(
          root_recording: root, account_recording: account, command_type: "usage_settlement",
          local_idempotency_key: "rated-usage-settlement:#{rated_usage.id}",
          provider_account_recording: terms.fetch(:provider_account_recording_id),
          provider_adapter_key: terms.fetch(:provider_adapter_key),
          commercial_manifest_digests: [rated_usage.manifest_digest], request:
        )
        return Result.new(status: :conflict, settlement: nil, command: command_result.command, reason: :command_conflict) if command_result.conflict?

        settlement = RatedUsageSettlement.create!(
          root_recording: root, account_recording: account, rated_usage:, financial_command: command_result.command,
          provider_account_recording_id: terms.fetch(:provider_account_recording_id), manifest_digest: rated_usage.manifest_digest,
          canonical_request: request, request_fingerprint: command_result.command.request_fingerprint,
          safe_metadata: SafeFinancialPayload.normalize(metadata)
        )
        Result.new(status: command_result.created? ? :created : :existing, settlement:, command: command_result.command, reason: nil)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    rescue ActiveRecord::RecordNotFound, ArgumentError
      Result.new(status: :denied, settlement: nil, command: nil, reason: :invalid_authority)
    end

    private

    attr_reader :metadata, :rated_usage_input, :root_recording_input

    def authority!
      root = RecordingStudio.root_recording_or_self(root_recording_input)
      RecordingStudio.assert_root_recording!(root)
      root = RecordingStudio::Recording.unscoped.find(root.id)
      account = Account.with_current_recording.find_by!(root_recording: root).recording
      raise ArgumentError, "billing account must belong directly to the normalized root" unless account.parent_recording_id == root.id && account.root_recording_id == root.id

      [root, account]
    end

    def authoritative_rated_usage(root, account)
      id = rated_usage_input.respond_to?(:id) ? rated_usage_input.id : rated_usage_input
      rated_usage = RatedUsage.lock.find(id)
      raise ArgumentError, "rated usage belongs to another root or account" unless rated_usage.root_recording_id == root.id && rated_usage.account_recording_id == account.id

      rated_usage
    end

    def settlement_terms(rated_usage)
      manifest = CommercialManifest.lock.find_by(manifest_digest: rated_usage.manifest_digest)
      return :unsupported unless manifest&.used_at?

      terms = manifest.canonical_data.fetch("usage_settlement")
      provider_id = terms.fetch("provider_account_recording_id")
      adapter_key = terms.fetch("provider_adapter_key")
      return :requires_review unless terms.fetch("operation") == "collect_usage" && provider_id.present? && adapter_key.present?
      return :requires_review unless rated_usage.rate_snapshot.dig("customer_rate", "currency_code") == rated_usage.customer_currency_code

      {
        provider_account_recording_id: provider_id,
        provider_adapter_key: adapter_key,
        market_recording_id: terms.fetch("market_recording_id"),
        market_country_codes: terms.fetch("market_country_codes"),
        collection_method: terms.fetch("collection_method")
      }
    rescue KeyError, TypeError
      :requires_review
    end

    def provider_capability(terms, rated_usage)
      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(terms.fetch(:provider_adapter_key))
      adapter.capabilities.evaluate(
        operations: "collect_usage", currencies: rated_usage.customer_currency_code,
        markets: terms.fetch(:market_country_codes), collection_methods: terms.fetch(:collection_method)
      )
    rescue KeyError, ArgumentError
      ProviderCapabilities::Evaluation.new(supported: false, reason: :provider_unavailable, explanation: nil, constraints: {})
    end

    def canonical_request(rated_usage, terms)
      SafeFinancialPayload.normalize({
        "rated_usage_id" => rated_usage.id, "meter_recording_id" => rated_usage.meter_aggregation.meter_recording_id,
        "rate_recording_id" => rated_usage.rate_recording_id, "customer_price_recording_id" => rated_usage.customer_price_recording_id,
        "market_recording_id" => terms.fetch(:market_recording_id), "collection_method" => terms.fetch(:collection_method),
        "amount_minor" => rated_usage.customer_amount_minor, "currency" => rated_usage.customer_currency_code,
        "currency_exponent" => rated_usage.customer_currency_exponent,
        "window_starts_at" => rated_usage.window_starts_at.utc.iso8601(6), "window_ends_at" => rated_usage.window_ends_at.utc.iso8601(6),
        "manifest_digest" => rated_usage.manifest_digest
      }, allow_authoritative_totals: true)
    end

    def existing_result(existing, request)
      return Result.new(status: :existing, settlement: existing, command: existing.financial_command, reason: nil) if existing.canonical_request == request

      Result.new(status: :conflict, settlement: existing, command: existing.financial_command, reason: :settlement_conflict)
    end
  end
end