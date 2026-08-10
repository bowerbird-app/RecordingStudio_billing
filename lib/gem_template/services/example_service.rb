# frozen_string_literal: true

module GemTemplate
  module Services
    # Example service demonstrating the service object pattern.
    #
    # This is a template—replace with your actual business logic.
    #
    # @example
    #   result = GemTemplate::Services::ExampleService.call(name: "World")
    #   result.value # => "Hello, World!"
    #
    class ExampleService < BaseService
      def initialize(name:)
        @name = name
      end

      private

      def perform
        return failure("Name cannot be blank") if @name.nil? || @name.strip.empty?

        greeting = "Hello, #{@name}!"
        success(greeting)
      end
    end
  end
end
