# frozen_string_literal: true

require_relative "hooks"

module RecordingStudioBilling
  class Configuration
    attr_reader :provider
    attr_reader :hooks

    def initialize
      @provider = :stripe
      @hooks = Hooks.new
    end

    def to_h
      {
        provider: provider,
        hooks_registered: hooks.instance_variable_get(:@registry).transform_values(&:size)
      }
    end

    def provider=(value)
      normalized_provider = value.to_s.strip
      raise ArgumentError, "provider must be present" if normalized_provider.empty?

      @provider = normalized_provider.to_sym
    end

    def merge!(hash)
      return unless hash.respond_to?(:each)

      hash.each do |k, v|
        key = k.to_s
        setter = "#{key}="
        public_send(setter, v) if respond_to?(setter)
      end
    end
  end
end
