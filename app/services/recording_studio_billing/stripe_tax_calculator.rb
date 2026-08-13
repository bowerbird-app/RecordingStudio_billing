# frozen_string_literal: true

module RecordingStudioBilling
  class StripeAdapter
    class TaxCalculator
      CAPABILITIES = TaxCalculatorCapabilities.new(
        mode: :external_calculation, transactions: %w[sale refund], currencies: %w[USD EUR GBP],
        markets: %w[AU CA DE ES FR GB IE IT NL NZ US], behaviors: %w[inclusive exclusive provider_default],
        location: true, classification: true, breakdown: true
      ).freeze

      attr_reader :capabilities

      def initialize(credential_resolver:, tax_code_resolver:, client_factory: nil, clock: -> { Time.current })
        unless credential_resolver.respond_to?(:call)
          raise ArgumentError,
                "stripe tax credential resolver must respond to call"
        end
        raise ArgumentError, "stripe tax code resolver must respond to call" unless tax_code_resolver.respond_to?(:call)

        @credential_resolver = credential_resolver
        @tax_code_resolver = tax_code_resolver
        @client_factory = client_factory || ->(secret_key) { Stripe::StripeClient.new(secret_key) }
        @clock = clock
        @capabilities = CAPABILITIES
      end

      def validate!(request:)
        payload = request_payload(request)
        payload.fetch("lines").each { |line| tax_code_for(line.fetch("tax_category")) }
      end

      def call(command:, request:, idempotency_key:)
        credential = credentials
        raise ArgumentError, "stripe tax configuration is missing" unless credential

        payload = request_payload(request)
        calculation = stripe_hash(stripe_client(credential).v1.tax.calculations.create(
                                    stripe_request(payload), { idempotency_key: }
                                  ))
        response_for(calculation, payload)
      end

      private

      def request_payload(request)
        normalized = request.to_h.stringify_keys
        normalized.fetch("request", normalized)
      end

      def credentials
        raw = @credential_resolver.call
        value = raw.is_a?(Hash) ? raw.symbolize_keys : { secret_key: raw }
        value[:secret_key].presence
      end

      def stripe_request(payload)
        request = {
          "currency" => payload.fetch("currency").downcase,
          "customer_details" => { "address" => stripe_address(payload.fetch("verified_location")) },
          "line_items" => tax_line_items(payload).map do |line|
            {
              "amount" => line.fetch("amount_minor"), "reference" => line.fetch("reference"),
              "tax_code" => tax_code_for(line.fetch("tax_category"))
            }
          end
        }
        request["tax_behavior"] = payload.fetch("behavior") unless payload.fetch("behavior") == "provider_default"
        request
      end

      def stripe_address(location)
        { "country" => location.fetch("country") }.tap do |address|
          address["state"] = location.fetch("region") if location["region"].present?
        end
      end

      def tax_line_items(payload)
        lines = payload.fetch("lines")
        remaining_discount = payload.fetch("discount_minor")
        remaining_amount = payload.fetch("subtotal_minor")
        lines.map do |line|
          amount = line.fetch("amount_minor")
          allocated_discount = remaining_amount.zero? ? 0 : (amount * remaining_discount / remaining_amount)
          remaining_discount -= allocated_discount
          remaining_amount -= amount
          line.merge("amount_minor" => amount - allocated_discount)
        end
      end

      def response_for(calculation, payload)
        behavior = payload.fetch("behavior") == "provider_default" ? "exclusive" : payload.fetch("behavior")
        tax = if behavior == "inclusive"
                calculation.fetch("tax_amount_inclusive",
                                  0)
              else
                calculation.fetch("tax_amount_exclusive", 0)
              end
        TaxResponse.new(
          status: "success", subtotal_minor: payload.fetch("subtotal_minor"), discount_minor: payload.fetch("discount_minor"),
          tax_minor: tax, total_minor: calculation.fetch("amount_total"), currency: payload.fetch("currency"), behavior:,
          calculator_reference: calculation.fetch("id"), calculated_at: Time.at(calculation.fetch("created", @clock.call.to_i)),
          request_fingerprint: CommercialManifestCanonicalizer.digest(payload), breakdown: normalize_breakdown(calculation),
          metadata: { "calculator" => "stripe_tax" }
        )
      end

      def normalize_breakdown(calculation)
        Array(calculation["tax_breakdown"]).filter_map do |entry|
          amount = entry["amount"]
          { "category" => "stripe", "amount_minor" => amount } if amount.is_a?(Integer)
        end
      end

      def tax_code_for(category)
        code = @tax_code_resolver.call(category.to_s)
        SafeFinancialPayload.normalize_reference(code.to_s, label: "Stripe tax code")
      end

      def stripe_client(secret_key)
        @client_factory.call(secret_key)
      end

      def stripe_hash(value)
        value.respond_to?(:to_hash) ? value.to_hash.stringify_keys : value.to_h.stringify_keys
      end
    end
  end
end
