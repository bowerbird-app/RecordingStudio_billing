# frozen_string_literal: true

module RecordingStudioBilling
  class TaxCalculatorRegistry
    KEY_FORMAT = ProviderRegistry::KEY_FORMAT

    def initialize
      @calculators = {}
      @mutex = Mutex.new
    end

    def register(key, calculator)
      normalized_key = normalize_key(key)
      capabilities = calculator.respond_to?(:capabilities) && calculator.capabilities
      unless capabilities.is_a?(TaxCalculatorCapabilities) && calculator.respond_to?(:call)
        raise ArgumentError, "tax calculator must implement the shared contract"
      end

      @mutex.synchronize do
        raise ArgumentError, "tax calculator key is already registered: #{normalized_key}" if @calculators.key?(normalized_key)

        @calculators[normalized_key] = calculator
      end
      calculator
    end

    def fetch(key)
      normalized_key = normalize_key(key)
      @mutex.synchronize { @calculators.fetch(normalized_key) }
    rescue KeyError
      raise ArgumentError, "unknown tax calculator key: #{normalized_key}"
    end

    def reset!
      @mutex.synchronize { @calculators.clear }
      self
    end

    def keys
      @mutex.synchronize { @calculators.keys.sort.freeze }
    end

    private

    def normalize_key(key)
      normalized = key.to_s.strip
      raise ArgumentError, "tax calculator key is invalid" unless normalized.match?(KEY_FORMAT)

      normalized
    end
  end
end