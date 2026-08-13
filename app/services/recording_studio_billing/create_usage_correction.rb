# frozen_string_literal: true

module RecordingStudioBilling
  class CreateUsageCorrection
    Result = Data.define(:status, :correction, :command, :reason) do
      def created? = status == :created
      def existing? = status == :existing
      def requires_review? = status == :requires_review
    end

    def self.call(...) = new(...).call

    def initialize(usage_allocation:, correction_kind:, quantity_delta:, reason:, metadata: {})
      @usage_allocation = usage_allocation
      @correction_kind = correction_kind
      @quantity_delta = quantity_delta
      @reason = reason
      @metadata = metadata
    end

    def call
      UsageCorrection.transaction(requires_new: true) do
        allocation = UsageAllocation.lock.find(usage_allocation.id)
        period = allocation.usage_period.lock!
        raise ArgumentError, "usage corrections require a closed period" unless period.state.in?(%w[closed submitted
                                                                                                    invoiced reconciled requires_review])

        settlement = RatedUsageSettlement.lock.find_by(usage_period: period)
        unless settlement
          return Result.new(status: :requires_review, correction: nil, command: nil,
                            reason: :usage_period_not_settled)
        end

        validate_correction!(allocation)
        correction_id = correction_id_for(allocation, settlement)
        existing = UsageCorrection.lock.find_by(id: correction_id)
        if existing
          return Result.new(status: :existing, correction: existing, command: existing.financial_command,
                            reason: nil)
        end

        request = correction_request(correction_id, allocation, settlement)
        tax = calculate_tax(correction_id, allocation, settlement, request)
        if tax.requires_review?
          return Result.new(status: :requires_review, correction: nil, command: nil,
                            reason: tax.reason)
        end

        request["tax"] = tax.canonical_details
        command_result = CreateFinancialCommand.call(
          root_recording: settlement.root_recording, account_recording: settlement.account_recording,
          command_type: "usage_correction", local_idempotency_key: "usage-correction:#{correction_id}",
          provider_account_recording: settlement.provider_account_recording,
          provider_adapter_key: settlement.financial_command.provider_adapter_key,
          commercial_manifest_digests: settlement.canonical_request.fetch("commercial_manifest_digests", [settlement.manifest_digest]), request:
        )
        if command_result.existing?
          return Result.new(status: :existing,
                            correction: UsageCorrection.find_by(financial_command: command_result.command), command: command_result.command, reason: nil)
        end
        raise ArgumentError, "usage correction command conflicts with existing authority" if command_result.conflict?

        correction = UsageCorrection.create!(id: correction_id, usage_allocation: allocation, correction_kind:, quantity_delta:, reason:,
                                             tax_calculation: tax.calculation, financial_command: command_result.command,
                                             safe_metadata: SafeFinancialPayload.normalize(metadata))
        append_adjustment!(period, allocation, correction)
        Result.new(status: :created, correction:, command: command_result.command, reason: nil)
      end
    end

    private

    attr_reader :correction_kind, :metadata, :quantity_delta, :reason, :usage_allocation

    def correction_request(correction_id, allocation, settlement)
      request = settlement.canonical_request
      amount_minor, cumulative_amount_minor = money_delta(allocation, settlement)
      {
        "usage_correction_id" => correction_id, "usage_period_id" => allocation.usage_period_id,
        "usage_allocation_id" => allocation.id, "settlement_id" => settlement.id,
        "correction_kind" => correction_kind.to_s, "quantity_delta" => Integer(quantity_delta), "reason" => reason.to_s,
        "amount_minor" => amount_minor, "cumulative_amount_minor" => cumulative_amount_minor,
        "currency" => request.fetch("currency"), "currency_exponent" => request.fetch("currency_exponent"),
        "market_recording_id" => request.fetch("market_recording_id"), "collection_method" => request.fetch("collection_method"),
        "commercial_manifest_digests" => request.fetch("commercial_manifest_digests", [settlement.manifest_digest])
      }
    end

    def calculate_tax(correction_id, allocation, settlement, request)
      policy = CommercialManifest.find_by!(manifest_digest: settlement.manifest_digest).canonical_data.fetch("tax_policy").stringify_keys
      return TaxGate.new(nil, nil) unless policy.fetch("enabled", false)

      source = settlement.canonical_request.fetch("tax").fetch("canonical_request")
      result = CalculateTax.call(
        calculator_key: policy.fetch("calculator_key"), tax_policy: policy,
        root_recording: settlement.root_recording, account_recording: settlement.account_recording,
        manifest: CommercialManifest.find_by!(manifest_digest: settlement.manifest_digest), transaction_type: "usage_correction",
        operation_reference: "usage-correction:#{correction_id}",
        lines: [{ reference: allocation.id, quantity: 1, amount_minor: request.fetch("amount_minor").abs,
                  tax_category: source.fetch("tax_categories").first }],
        subtotal_minor: request.fetch("amount_minor").abs, discount_minor: 0, currency: request.fetch("currency"),
        verified_location: source.fetch("verified_location"), tax_categories: source.fetch("tax_categories"),
        behavior: source.fetch("behavior"), effective_at: allocation.usage_period.ends_at,
        idempotency_key: "usage-correction-tax:#{correction_id}"
      )
      TaxGate.new(result.calculation, result.final? ? nil : :tax_not_final)
    rescue KeyError, ActiveRecord::RecordNotFound, ArgumentError
      TaxGate.new(nil, :tax_authority_unavailable)
    end

    def correction_id_for(allocation, settlement)
      payload = {
        "usage_allocation_id" => allocation.id, "settlement_id" => settlement.id,
        "correction_kind" => correction_kind.to_s, "quantity_delta" => Integer(quantity_delta), "reason" => reason.to_s
      }
      digest = CommercialManifestCanonicalizer.digest(payload)
      "#{digest[0, 8]}-#{digest[8, 4]}-#{digest[12, 4]}-#{digest[16, 4]}-#{digest[20, 12]}"
    end

    def validate_correction!(allocation)
      delta = Integer(quantity_delta)
      expected_sign = { "credit" => -1, "debit" => 1, "void" => -1 }.fetch(correction_kind.to_s)
      raise ArgumentError, "usage correction has an invalid sign" unless delta.positive? == expected_sign.positive?

      corrected_quantity = allocation.excess_quantity + allocation.usage_corrections.sum(:quantity_delta) + delta
      raise ArgumentError, "usage correction exceeds the allocable quantity" unless corrected_quantity.between?(0, allocation.measured_quantity)
    rescue KeyError, ArgumentError, TypeError
      raise ArgumentError, "usage correction is invalid"
    end

    def money_delta(allocation, settlement)
      rate = allocation.rated_usage.rate_snapshot.fetch("customer_rate")
      settled = settlement.canonical_request.fetch("allocations").find do |entry|
        entry.fetch("usage_allocation_id") == allocation.id
      end
      raise ArgumentError, "usage correction allocation is absent from the settlement authority" unless settled

      base_quantity = allocation.excess_quantity
      base_amount = amount_for(base_quantity, rate)
      raise ArgumentError, "usage correction settlement monetary authority is invalid" unless settled.fetch("excess_quantity") == base_quantity && settled.fetch("amount_minor") == base_amount

      previous_delta = allocation.usage_corrections.sum(:quantity_delta)
      previous_amount = amount_for(base_quantity + previous_delta, rate) - base_amount
      cumulative_amount = amount_for(base_quantity + previous_delta + Integer(quantity_delta), rate) - base_amount
      [cumulative_amount - previous_amount, cumulative_amount]
    end

    def amount_for(quantity, rate)
      package_size = Integer(rate.fetch("package_size", 1) || 1)
      raise ArgumentError, "usage correction package size is invalid" unless package_size.positive?

      ((Integer(quantity) * Integer(rate.fetch("amount_minor"))) + package_size - 1) / package_size
    end

    def append_adjustment!(period, allocation, correction)
      UsageLedgerEntry.create!(
        root_recording: allocation.root_recording, account_recording: allocation.account_recording, usage_period: period,
        usage_allocation: allocation, entry_kind: "adjustment", quantity: correction.quantity_delta.abs,
        sequence: period.usage_ledger_entries.maximum(:sequence).to_i + 1,
        safe_metadata: { "usage_correction_id" => correction.id, "correction_kind" => correction.correction_kind,
                         "quantity_delta" => correction.quantity_delta }
      )
    end

    TaxGate = Data.define(:calculation, :reason) do
      def requires_review? = reason.present?

      def canonical_details
        return {} unless calculation

        { "calculation_id" => calculation.id, "request_fingerprint" => calculation.financial_command.request_fingerprint,
          "canonical_request" => calculation.financial_command.canonical_request.fetch("request"),
          "normalized_result" => calculation.financial_command.normalized_result }
      end
    end
  end
end
