# frozen_string_literal: true

module RecordingStudioBilling
  class CalculateTax
    Result = Data.define(:status, :calculation, :response) do
      def final? = calculation&.final? == true
    end

    class ValidatingAdapter
      def initialize(calculator)
        @calculator = calculator
      end

      def validate!(request:)
        calculator.validate!(request:) if calculator.respond_to?(:validate!)
      end

      def call(command:, request:, idempotency_key:)
        response = calculator.call(command:, request:, idempotency_key:)
        raise ArgumentError, "tax calculator must return a TaxResponse" unless response.is_a?(TaxResponse)

        payload = request.fetch("request")
        expected = {
          subtotal_minor: payload.fetch("subtotal_minor"), discount_minor: payload.fetch("discount_minor"),
          currency: payload.fetch("currency"), request_fingerprint: CommercialManifestCanonicalizer.digest(payload)
        }
        mismatched = expected.any? { |attribute, value| response.public_send(attribute) != value }
        if payload.fetch("behavior") != "provider_default"
          mismatched ||= response.behavior != payload.fetch("behavior")
        end
        raise ArgumentError, "tax calculator response does not match the authoritative request" if mismatched

        response
      end

      private

      attr_reader :calculator
    end

    def self.call(**attributes)
      new(**attributes).call
    end

    def initialize(calculator_key:, **request_attributes)
      @calculator_key = calculator_key.to_s
      @request_attributes = request_attributes
    end

    def call
      return unsupported("tax_disabled") unless approved_policy?

      request = TaxRequest.new(**request_attributes)
      calculator = registry.fetch(calculator_key)
      evaluation = calculator.capabilities.evaluate(
        transaction: request.transaction_type, currency: request.currency,
        market: request.verified_location.fetch("country"), behavior: request.behavior,
        location: true, classification: request.tax_categories.any?
      )
      return unsupported(evaluation.reason) unless evaluation.supported?

      with_idempotency_lock(request) do
        command_result = FinancialCommandExecutor.call_tax(
          calculator_key:, calculator_mode: calculator.capabilities.mode,
          root_recording: request.root_recording, account_recording: request.account_recording,
          command_type: "tax_calculation", local_idempotency_key: request.idempotency_key,
          commercial_manifest_digests: [request.manifest.manifest_digest], request: request.to_h
        )
        command = command_result.command.reload
        return conflict(command) if command_result.conflict?

        calculation = PersistTaxCalculation.call(command:)
        Result.new(status: calculation.status.to_sym, calculation:, response: command.normalized_result)
      end
    rescue ArgumentError => error
      unsupported(error.message.include?("unknown tax calculator") ? "unknown_calculator" : "invalid")
    end

    private

    attr_reader :calculator_key, :request_attributes

    def approved_policy?
      policy = RecordingStudioBilling.configuration.tax_policy
      policy.fetch(:enabled) && policy.fetch(:calculator_key).to_s == calculator_key
    end

    def registry
      RecordingStudioBilling.configuration.tax_calculator_registry
    end

    def with_idempotency_lock(request)
      connection = FinancialCommand.connection
      lock_key = "tax:#{request.root_recording.id}:#{request.idempotency_key}"
      sql = FinancialCommand.sanitize_sql_array(["SELECT pg_advisory_lock(hashtextextended(?, 0))", lock_key])
      connection.select_value(sql)
      yield
    ensure
      if connection
        sql = FinancialCommand.sanitize_sql_array(["SELECT pg_advisory_unlock(hashtextextended(?, 0))", lock_key])
        connection.select_value(sql)
      end
    end

    def unsupported(reason)
      response = AdapterResponse.new(
        status: "unsupported_tax_calculation", result: { "reason" => reason,
          "explanation" => "Tax calculation is disabled or unsupported." }
      )
      Result.new(status: :unsupported_tax_calculation, calculation: nil, response: response.result)
    end

    def conflict(command)
      response = AdapterResponse.new(status: "conflict", result: { "command_id" => command.id })
      Result.new(status: :conflict, calculation: TaxCalculation.find_by(financial_command_id: command.id),
                 response: response.result)
    end
  end
end