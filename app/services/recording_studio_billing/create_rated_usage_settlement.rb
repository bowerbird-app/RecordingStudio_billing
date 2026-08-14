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

    def initialize(root_recording:, usage_period: nil, rated_usage: nil, metadata: {})
      @root_recording_input = root_recording
      @usage_period_input = usage_period
      @rated_usage_input = rated_usage
      @metadata = metadata
    end

    def call
      root, account = authority!
      RatedUsageSettlement.transaction(requires_new: true) do
        period = authoritative_period(root, account, lock: true)
        existing = RatedUsageSettlement.find_by(usage_period: period)
        if existing
          return Result.new(status: :existing, settlement: existing, command: existing.financial_command,
                            reason: nil)
        end
        return Result.new(status: :requires_review, settlement: nil, command: nil, reason: :usage_period_not_closed) unless period.state == "closed"

        allocations = period.usage_allocations.includes(:rated_usage).order(:created_at, :id).to_a
        if allocations.empty?
          return Result.new(status: :requires_review, settlement: nil, command: nil,
                            reason: :usage_period_empty)
        end

        overages = allocations.to_h { |allocation| [allocation.id, CalculateOverage.call(allocation:)] }.compact
        terms = settlement_terms(allocations)
        return Result.new(status: terms, settlement: nil, command: nil, reason: terms) if terms.is_a?(Symbol)

        unless compatible_money?(overages)
          return Result.new(status: :requires_review, settlement: nil, command: nil,
                            reason: :incompatible_currency_terms)
        end

        safety = safety_gate(overages)
        if safety
          period.update!(state: "requires_review") if period.state == "closed"
          return Result.new(status: :requires_review, settlement: nil, command: nil, reason: safety)
        end

        capability = provider_capability(terms, allocations.first.rated_usage)
        unless capability.supported?
          return Result.new(status: :unsupported, settlement: nil, command: nil,
                            reason: capability.reason)
        end

        request = canonical_request(period, allocations, overages, terms)
        tax = calculate_tax(root, account, period, allocations, request, terms)
        if tax.requires_review?
          return Result.new(status: :requires_review, settlement: nil, command: nil,
                            reason: tax.reason)
        end

        request = request.merge("tax" => tax.canonical_details)

        command_result = CreateFinancialCommand.call(
          root_recording: root, account_recording: account, command_type: "usage_settlement",
          local_idempotency_key: "usage-period-settlement:#{period.id}",
          provider_account_recording: terms.fetch(:provider_account_recording_id),
          provider_adapter_key: terms.fetch(:provider_adapter_key),
          commercial_manifest_digests: allocations.map(&:rated_usage).map(&:manifest_digest).uniq.sort, request:
        )
        if command_result.conflict?
          return Result.new(status: :conflict, settlement: nil, command: command_result.command,
                            reason: :command_conflict)
        end

        settlement = RatedUsageSettlement.create!(
          root_recording: root, account_recording: account, usage_period: period, financial_command: command_result.command,
          provider_account_recording_id: terms.fetch(:provider_account_recording_id), manifest_digest: allocations.first.rated_usage.manifest_digest,
          canonical_request: request, request_fingerprint: command_result.command.request_fingerprint,
          safe_metadata: SafeFinancialPayload.normalize(metadata.merge("calculation_id" => tax.calculation&.id))
        )
        period.update!(state: "submitted")
        Result.new(status: command_result.created? ? :created : :existing, settlement:,
                   command: command_result.command, reason: nil)
      end
    rescue CalculateOverage::AuthorityError => e
      Result.new(status: :requires_review, settlement: nil, command: nil, reason: e.reason)
    rescue ActiveRecord::RecordNotFound, ArgumentError
      Result.new(status: :denied, settlement: nil, command: nil, reason: :invalid_authority)
    end

    private

    attr_reader :metadata, :rated_usage_input, :root_recording_input, :usage_period_input

    def authority!
      root = RecordingStudio.root_recording_or_self(root_recording_input)
      RecordingStudio.assert_root_recording!(root)
      root = RecordingStudio::Recording.unscoped.find(root.id)
      account = Account.with_current_recording.find_by!(root_recording: root).recording
      unless account.parent_recording_id == root.id && account.root_recording_id == root.id
        raise ArgumentError,
              "billing account must belong directly to the normalized root"
      end

      [root, account]
    end

    def authoritative_period(root, account, lock: false)
      if usage_period_input
        id = usage_period_input.respond_to?(:id) ? usage_period_input.id : usage_period_input
        period = lock ? UsagePeriod.lock.find(id) : UsagePeriod.find(id)
      elsif rated_usage_input
        rated_id = rated_usage_input.respond_to?(:id) ? rated_usage_input.id : rated_usage_input
        allocation = lock ? UsageAllocation.lock.find_by!(rated_usage_id: rated_id) : UsageAllocation.find_by!(rated_usage_id: rated_id)
        period = lock ? UsagePeriod.lock.find(allocation.usage_period_id) : allocation.usage_period
      else
        raise ArgumentError, "usage period is required"
      end
      unless period.root_recording_id == root.id && period.account_recording_id == account.id
        raise ArgumentError,
              "usage period belongs to another root or account"
      end

      period
    end

    def settlement_terms(allocations)
      terms = allocations.map do |allocation|
        manifest = CommercialManifest.lock.find_by(manifest_digest: allocation.rated_usage.manifest_digest)
        return :unsupported unless manifest&.used_at?

        manifest.canonical_data.fetch("usage_settlement")
      end
      return :requires_review unless terms.map { |term| canonical_terms(term) }.uniq.one?

      terms = terms.first.stringify_keys
      provider_id = terms.fetch("provider_account_recording_id")
      adapter_key = terms.fetch("provider_adapter_key")
      return :requires_review unless terms.fetch("operation") == "collect_usage" && provider_id.present? && adapter_key.present?

      {
        provider_account_recording_id: provider_id,
        provider_adapter_key: adapter_key,
        market_recording_id: terms.fetch("market_recording_id"),
        resolved_country_code: terms.fetch("resolved_country_code"),
        resolution_tier: terms.fetch("resolution_tier"),
        market_geography: terms.fetch("market_geography"),
        collection_method: terms.fetch("collection_method"),
        tax_policy: manifest_tax_policy(allocations)
      }
    rescue KeyError, TypeError
      :requires_review
    end

    def manifest_tax_policy(allocations)
      policies = allocations.map do |allocation|
        CommercialManifest.lock.find_by!(manifest_digest: allocation.rated_usage.manifest_digest)
                          .canonical_data.fetch("tax_policy")
      end
      raise ArgumentError, "usage allocations have incompatible tax policies" unless policies.uniq.one?

      policies.sole.stringify_keys
    end

    def provider_capability(terms, rated_usage)
      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(terms.fetch(:provider_adapter_key))
      adapter.capabilities.evaluate(
        operations: "collect_usage", currencies: rated_usage.rate_snapshot.dig("customer_rate", "currency_code"),
        markets: provider_markets(terms), collection_methods: terms.fetch(:collection_method)
      )
    rescue KeyError, ArgumentError
      ProviderCapabilities::Evaluation.new(supported: false, reason: :provider_unavailable, explanation: nil,
                                           constraints: {})
    end

    def canonical_terms(terms)
      terms.stringify_keys.slice(
        "provider_account_recording_id", "provider_adapter_key", "market_recording_id", "resolved_country_code",
        "resolution_tier", "market_geography",
        "collection_method", "operation", "tax", "manifest_policy"
      )
    end

    def compatible_money?(overages)
      return true if overages.empty?

      overages.values.map { |overage| [overage.currency_code, overage.currency_exponent] }.uniq.one?
    end

    def safety_gate(overages)
      return if overages.empty?

      limits = overages.values.map { |overage| overage.rate_snapshot.fetch("safety_limits", {}).stringify_keys }
      return :overage_safety_limits_ambiguous unless limits.uniq.one?

      limits = limits.sole
      amount = overages.values.sum(&:amount_minor)
      hard = integer_limit(limits["hard_threshold_minor"])
      maximum_liability = integer_limit(limits["maximum_period_liability_minor"])
      maximum_submission = integer_limit(limits["maximum_submission_minor"])
      review = integer_limit(limits["review_threshold_minor"])
      return :overage_hard_threshold_exceeded if hard && amount > hard
      return :overage_period_liability_exceeded if maximum_liability && amount > maximum_liability
      return :overage_submission_limit_exceeded if maximum_submission && amount > maximum_submission

      :overage_review_threshold_exceeded if review && amount > review
    end

    def integer_limit(value)
      return if value.nil?

      limit = Integer(value)
      raise ArgumentError, "overage safety limit must be non-negative" if limit.negative?

      limit
    rescue ArgumentError, TypeError
      raise CalculateOverage::AuthorityError, :overage_safety_limits_invalid
    end

    def provider_markets(terms)
      geography = terms.fetch(:market_geography).to_h
      countries = Array(geography["country_codes"]) + Array(geography["regional_country_codes"])
      countries.concat(geography.fetch("country_groups", {}).values.flatten)
      countries << terms.fetch(:resolved_country_code) if terms.fetch(:resolved_country_code).present?
      countries.uniq
    end

    def canonical_request(period, allocations, overages, terms)
      SafeFinancialPayload.normalize({
                                       "usage_period_id" => period.id, "usage_key" => period.usage_key,
                                       "allocations" => allocations.map do |allocation|
                                         rated = allocation.rated_usage
                                         overage = overages[allocation.id]
                                         { "rated_usage_id" => rated.id, "usage_allocation_id" => allocation.id,
                                           "meter_recording_id" => rated.meter_aggregation.meter_recording_id, "credited_quantity" => allocation.credited_quantity,
                                           "excess_quantity" => allocation.excess_quantity, "amount_minor" => overage&.amount_minor || 0 }
                                       end,
                                       "market_recording_id" => terms.fetch(:market_recording_id), "collection_method" => terms.fetch(:collection_method),
                                       "amount_minor" => overages.values.sum(&:amount_minor), "currency" => settlement_currency(allocations, overages).first,
                                       "currency_exponent" => settlement_currency(allocations, overages).last,
                                       "commercial_manifest_digests" => allocations.map do |allocation|
                                         allocation.rated_usage.manifest_digest
                                       end.uniq.sort,
                                       "window_starts_at" => period.starts_at.utc.iso8601(6), "window_ends_at" => period.ends_at.utc.iso8601(6)
                                     }, allow_authoritative_totals: true)
    end

    def settlement_currency(allocations, overages)
      return [overages.values.first.currency_code, overages.values.first.currency_exponent] if overages.present?

      money = allocations.map do |allocation|
        rate = allocation.rated_usage.rate_snapshot.fetch("customer_rate")
        [rate.fetch("currency_code"), Integer(rate.fetch("currency_exponent"))]
      end
      raise CalculateOverage::AuthorityError, :incompatible_currency_terms unless money.uniq.one?

      money.sole
    rescue KeyError, ArgumentError, TypeError
      raise CalculateOverage::AuthorityError, :incompatible_currency_terms
    end

    def calculate_tax(root, account, period, allocations, request, terms)
      tax = terms.fetch(:tax_policy)
      return TaxGate.new(nil, nil) unless tax.fetch("enabled", false)

      result = CalculateTax.call(
        calculator_key: tax.fetch("calculator_key"), tax_policy: tax, root_recording: root,
        account_recording: account, manifest: CommercialManifest.find_by!(manifest_digest: allocations.first.rated_usage.manifest_digest), transaction_type: "usage_settlement",
        operation_reference: "usage-period:#{period.id}", lines: [{ reference: period.id, quantity: 1,
                                                                    amount_minor: request.fetch("amount_minor"), tax_category: tax.fetch("semantic_categories").first || "standard" }],
        subtotal_minor: request.fetch("amount_minor"), discount_minor: 0, currency: request.fetch("currency"),
        verified_location: { country: terms.fetch(:resolved_country_code) }, tax_categories: [tax.fetch("semantic_categories").first || "standard"],
        behavior: tax.fetch("presentation", "provider_default"), effective_at: period.ends_at,
        idempotency_key: "usage-period-tax:#{period.id}"
      )
      TaxGate.new(result.calculation, result.final? ? nil : :tax_not_final)
    rescue KeyError, ArgumentError
      TaxGate.new(nil, :tax_authority_unavailable)
    end

    TaxGate = Data.define(:calculation, :reason) do
      def requires_review? = reason.present?

      def canonical_details
        return {} unless calculation

        {
          "calculation_id" => calculation.id,
          "request_fingerprint" => calculation.financial_command.request_fingerprint,
          "canonical_request" => calculation.financial_command.canonical_request.fetch("request"),
          "normalized_result" => calculation.financial_command.normalized_result
        }
      end
    end

    def existing_result(existing, request)
      if existing.canonical_request == request
        return Result.new(status: :existing, settlement: existing, command: existing.financial_command,
                          reason: nil)
      end

      Result.new(status: :conflict, settlement: existing, command: existing.financial_command,
                 reason: :settlement_conflict)
    end
  end
end
