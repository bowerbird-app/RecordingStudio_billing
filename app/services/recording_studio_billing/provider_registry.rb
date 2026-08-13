# frozen_string_literal: true

module RecordingStudioBilling
  class ProviderRegistry
    KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/

    def initialize
      @adapters = {}
      @mutex = Mutex.new
    end

    def register(key, adapter)
      normalized_key = normalize_key(key)
      raise ArgumentError, "provider adapter must declare ProviderCapabilities" unless adapter.respond_to?(:capabilities) && adapter.capabilities.is_a?(ProviderCapabilities)
      raise ArgumentError, "provider adapter must respond to call" unless adapter.respond_to?(:call)

      @mutex.synchronize do
        if @adapters.key?(normalized_key)
          raise ArgumentError,
                "provider adapter key is already registered: #{normalized_key}"
        end

        @adapters[normalized_key] = adapter
      end
      adapter
    end

    def fetch(key)
      normalized_key = normalize_key(key)
      @mutex.synchronize { @adapters.fetch(normalized_key) }
    rescue KeyError
      raise ArgumentError, "unknown provider adapter key: #{normalized_key}"
    end

    def registered?(key)
      normalized_key = normalize_key(key)
      @mutex.synchronize { @adapters.key?(normalized_key) }
    end

    def reset!
      @mutex.synchronize { @adapters.clear }
      self
    end

    def keys
      @mutex.synchronize { @adapters.keys.sort.freeze }
    end

    private

    def normalize_key(key)
      normalized = key.to_s.strip
      raise ArgumentError, "provider adapter key is invalid" unless normalized.match?(KEY_FORMAT)

      normalized
    end
  end
end
