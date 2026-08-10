# frozen_string_literal: true

module GemTemplate
  module Services
    # Base class for service objects following the Command pattern.
    #
    # Services encapsulate business logic and provide a consistent interface
    # with `.call` class method and a Result object for success/failure handling.
    #
    # Services support hooks for instrumentation and customization:
    # - before_service: Called before service execution
    # - after_service: Called after service execution (with result)
    # - around_service: Wraps service execution
    #
    # @example Basic usage
    #   result = MyService.call(param1: "value")
    #   if result.success?
    #     puts result.value
    #   else
    #     puts result.error
    #   end
    #
    # @example With block for error handling
    #   MyService.call(param1: "value") do |result|
    #     result.on_success { |value| puts "Success: #{value}" }
    #     result.on_failure { |error| puts "Error: #{error}" }
    #   end
    #
    class BaseService
      # Result object returned by all services
      class Result
        attr_reader :value, :error, :errors

        def initialize(success:, value: nil, error: nil, errors: [])
          @success = success
          @value = value
          @error = error
          @errors = errors
        end

        def success?
          @success
        end

        def failure?
          !@success
        end

        def on_success
          yield(value) if success? && block_given?
          self
        end

        def on_failure
          yield(error, errors) if failure? && block_given?
          self
        end

        # Unwrap the value or raise an error
        def value!
          raise error if failure?

          value
        end
      end

      class << self
        # Main entry point for calling the service
        #
        # @param args [Hash] Arguments passed to the service
        # @yield [Result] Optional block for handling the result
        # @return [Result] The result of the service call
        def call(*, **, &)
          new(*, **).call(&)
        end
      end

      # Execute the service logic with hooks
      #
      # @yield [Result] Optional block for handling the result
      # @return [Result] The result of the service call
      def call
        # Run before_service hooks
        run_before_hooks

        # Run around_service hooks (or just perform if none registered)
        result = run_with_around_hooks

        # Run after_service hooks
        run_after_hooks(result)

        yield(result) if block_given?
        result
      end

      private

      # Override this method in subclasses to implement service logic
      #
      # @return [Result] The result of the operation
      def perform
        raise NotImplementedError, "#{self.class}#perform must be implemented"
      end

      # Helper to return a success result
      #
      # @param value [Object] The successful value
      # @return [Result] A success result
      def success(value = nil)
        Result.new(success: true, value: value)
      end

      # Helper to return a failure result
      #
      # @param error [String, StandardError] The error message or exception
      # @param errors [Array] Additional error details
      # @return [Result] A failure result
      def failure(error, errors: [])
        error_message = error.is_a?(Exception) ? error.message : error
        Result.new(success: false, error: error_message, errors: errors)
      end

      # Run before_service hooks
      def run_before_hooks
        return unless hooks_enabled?

        GemTemplate::Hooks.run(:before_service, self.class, service_args)
      end

      # Run after_service hooks
      #
      # @param result [Result] The service result
      def run_after_hooks(result)
        return unless hooks_enabled?

        GemTemplate::Hooks.run(:after_service, self.class, result)
      end

      # Run perform wrapped in around_service hooks
      #
      # @return [Result] The service result
      def run_with_around_hooks
        if hooks_enabled? && GemTemplate.configuration.hooks.registered?(:around_service)
          GemTemplate::Hooks.run_around(:around_service, self) { perform }
        else
          perform
        end
      end

      # Check if hooks are enabled (GemTemplate is loaded and configured)
      #
      # @return [Boolean]
      def hooks_enabled?
        defined?(GemTemplate) &&
          GemTemplate.respond_to?(:configuration) &&
          GemTemplate.configuration.respond_to?(:hooks)
      end

      # Get service arguments for hook callbacks
      # Override in subclasses to provide meaningful args
      #
      # @return [Hash] Arguments passed to the service
      def service_args
        {}
      end
    end
  end
end
