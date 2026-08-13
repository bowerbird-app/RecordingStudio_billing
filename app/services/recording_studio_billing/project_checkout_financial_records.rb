# frozen_string_literal: true

module RecordingStudioBilling
  class ProjectCheckoutFinancialRecords
    def self.call(checkout_intent:, root_recording:) = new(checkout_intent:, root_recording:).call

    def initialize(checkout_intent:, root_recording:)
      @checkout_intent_input = checkout_intent
      @root_recording_input = root_recording
    end

    def call
      CheckoutIntent.transaction do
        intent = CheckoutIntent.for_root(root_recording_input).lock.find(intent_id)
        command = intent.financial_command
        raise ArgumentError, "checkout has not completed" unless command&.state == "succeeded"

        result = command.normalized_result
        authoritative = authoritative_result(result, command:)
        unless reconciles?(intent, authoritative)
          create_reconciliation!(command, intent, result)
          intent.update!(state: "requires_review") unless intent.state == "requires_review"
          raise ArgumentError, "checkout provider financial result requires reconciliation"
        end

        persist_native_tax!(intent, command, authoritative)
        invoice = project_invoice!(intent, command, authoritative)
        payment = Payment.find_or_create_by!(financial_command: command) do |record|
          record.root_recording = intent.root_recording
          record.account_recording = intent.account_recording
          record.invoice = invoice
          record.provider_reference = command.provider_reference
          record.currency_code = authoritative.fetch("currency")
          record.subtotal_minor = authoritative.fetch("subtotal_minor")
          record.discount_minor = authoritative.fetch("discount_minor")
          record.tax_minor = authoritative.fetch("tax_minor")
          record.amount_minor = authoritative.fetch("total_minor")
          record.state = authoritative.fetch("payment_state")
          record.safe_snapshot = { "checkout_intent_id" => intent.id, "manifest_digests" => intent.items.map(&:manifest_digest),
                                   "provider_lines" => authoritative.fetch("lines") }
          record.recorded_at = Time.current
        end
        payment.allocations.find_or_create_by!(invoice:) { |allocation| allocation.amount_minor = payment.amount_minor }
        payment
      end
    end

    private

    attr_reader :checkout_intent_input, :root_recording_input

    def intent_id = checkout_intent_input.respond_to?(:id) ? checkout_intent_input.id : checkout_intent_input

    def authoritative_result(result, command:)
      keys = %w[subtotal_minor discount_minor tax_minor total_minor currency payment_state lines]
      raise ArgumentError, "provider financial result is incomplete" unless keys.all? { |key| result.key?(key) }

      values = result.slice(*keys)
      if native_tax_enabled?(result, command:)
        tax_keys = %w[behavior breakdown calculator_reference calculated_at]
        raise ArgumentError, "provider native tax result is incomplete" unless tax_keys.all? { |key| result.key?(key) }

        values.merge!(result.slice(*tax_keys))
      end
      raise ArgumentError, "provider financial lines are invalid" unless values["lines"].is_a?(Array)

      line_keys = %w[checkout_intent_item_id manifest_digest currency quantity unit_amount_minor subtotal_minor
                     discount_minor tax_minor total_minor]
      raise ArgumentError, "provider financial lines are incomplete" unless values["lines"].all? { |line| line.is_a?(Hash) && line_keys.all? { |key| line.key?(key) } }
      raise ArgumentError, "provider financial amounts are invalid" unless %w[subtotal_minor discount_minor tax_minor
                                                                              total_minor].all? do |key|
        values[key].is_a?(Integer) && values[key] >= 0
      end

      unless values["total_minor"] == values["subtotal_minor"] - values["discount_minor"] + values["tax_minor"]
        raise ArgumentError,
              "provider financial arithmetic is invalid"
      end

      values
    end

    def native_tax_enabled?(_result, command:)
      command.canonical_request.dig("request", "tax", "enabled") == true &&
        command.canonical_request.dig("request", "tax", "mode") == "provider_native"
    end

    def reconciles?(intent, result)
      expected_subtotal = intent.items.sum do |item|
        item.commercial_manifest.dig("canonical_data", "price", "amount_minor") * item.quantity
      end
      return false unless result["currency"] == intent.items.first.currency_code && result["subtotal_minor"] == expected_subtotal

      expected = intent.items.index_by(&:id)
      provider_ids = result["lines"].map { |line| line["checkout_intent_item_id"] }
      return false unless provider_ids.uniq.size == provider_ids.size && provider_ids.sort == expected.keys.sort

      lines_reconcile = result["lines"].all? do |line|
        item = expected.fetch(line.fetch("checkout_intent_item_id"))
        price = item.commercial_manifest.dig("canonical_data", "price", "amount_minor")
        quantity = item.quantity
        approved_discount = item.commercial_manifest.dig("canonical_data", "discount_policy", "amount_minor") || 0
        tax = line.fetch("tax_minor", 0)
        line["manifest_digest"] == item.manifest_digest && line["currency"] == item.currency_code &&
          line["quantity"] == quantity && line["unit_amount_minor"] == price &&
          line["subtotal_minor"] == price * quantity && line.fetch("discount_minor", 0) == approved_discount &&
          line["total_minor"] == line["subtotal_minor"] - line.fetch("discount_minor", 0) + tax
      end
      return false unless lines_reconcile

      %w[subtotal_minor discount_minor tax_minor total_minor].all? do |key|
        result[key] == result["lines"].sum { |line| line.fetch(key) }
      end
    end

    def create_reconciliation!(command, intent, result)
      return unless defined?(ReconciliationIssue)

      ReconciliationIssue.find_or_create_by!(financial_command: command, authority: "checkout_financial_projection",
                                             kind: "provider_terms_mismatch") do |issue|
        issue.state = "open"
        issue.safe_payload = { "checkout_intent_id" => intent.id, "provider_result" => result,
                               "manifest_digests" => intent.items.map(&:manifest_digest) }
      end
    end

    def persist_native_tax!(intent, command, result)
      tax = command.canonical_request.dig("request", "tax").to_h.stringify_keys
      return unless tax["enabled"] == true && tax["mode"] == "provider_native"

      manifest = CommercialManifest.find_by!(manifest_digest: intent.items.first.manifest_digest)
      TaxCalculation.find_or_create_by!(financial_command: command, revision_number: 1) do |calculation|
        calculation.root_recording = intent.root_recording
        calculation.account_recording = intent.account_recording
        calculation.commercial_manifest = manifest
        calculation.calculator_key = tax.fetch("calculator_key")
        calculation.calculator_mode = "provider_calculation"
        calculation.manifest_digest = manifest.manifest_digest
        calculation.transaction_type = "sale"
        calculation.operation_reference = command.operation_id
        calculation.request_fingerprint = command.request_fingerprint
        calculation.idempotency_key = command.provider_idempotency_key
        calculation.subtotal_minor = result.fetch("subtotal_minor")
        calculation.discount_minor = result.fetch("discount_minor")
        calculation.tax_minor = result.fetch("tax_minor")
        calculation.total_minor = result.fetch("total_minor")
        calculation.currency = result.fetch("currency")
        calculation.behavior = result.fetch("behavior")
        calculation.status = "success"
        calculation.breakdown = result.fetch("breakdown")
        calculation.calculator_reference = result.fetch("calculator_reference")
        calculation.calculated_at = result.fetch("calculated_at")
        calculation.safe_metadata = command.attempts.order(:attempt_number).last.safe_metadata
      end
    end

    def project_invoice!(intent, command, result)
      Invoice.find_or_create_by!(financial_command: command) do |invoice|
        invoice.root_recording = intent.root_recording
        invoice.account_recording = intent.account_recording
        invoice.provider_reference = command.provider_reference
        invoice.currency_code = result.fetch("currency")
        invoice.subtotal_minor = result.fetch("subtotal_minor")
        invoice.discount_minor = result.fetch("discount_minor")
        invoice.tax_minor = result.fetch("tax_minor")
        invoice.total_minor = result.fetch("total_minor")
        invoice.state = result.fetch("payment_state")
        invoice.issued_at = Time.current
        invoice.safe_snapshot = { "checkout_intent_id" => intent.id,
                                  "manifest_digests" => intent.items.map(&:manifest_digest) }
        items = intent.items.index_by(&:id)
        result.fetch("lines").each do |line|
          item = items.fetch(line.fetch("checkout_intent_item_id"))
          invoice.lines.build(description: line.fetch("description", "Checkout item #{item.id}"), currency_code: result.fetch("currency"),
                              amount_minor: line.fetch("total_minor"), quantity: line.fetch("quantity"),
                              manifest_digest: item.manifest_digest, safe_snapshot: line)
        end
      end
    end
  end
end
