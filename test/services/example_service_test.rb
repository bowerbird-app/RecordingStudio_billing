# frozen_string_literal: true

require "test_helper"

module GemTemplate
  module Services
    class ExampleServiceTest < Minitest::Test
      def test_success_with_valid_name
        result = ExampleService.call(name: "World")

        assert result.success?
        assert_equal "Hello, World!", result.value
      end

      def test_failure_with_blank_name
        result = ExampleService.call(name: "")

        assert result.failure?
        assert_equal "Name cannot be blank", result.error
      end

      def test_failure_with_nil_name
        result = ExampleService.call(name: nil)

        assert result.failure?
        assert_equal "Name cannot be blank", result.error
      end

      def test_failure_with_whitespace_only_name
        result = ExampleService.call(name: "   ")

        assert result.failure?
        assert_equal "Name cannot be blank", result.error
      end

      def test_block_syntax
        greeting = nil

        ExampleService.call(name: "Ruby") do |result|
          result.on_success { |value| greeting = value }
        end

        assert_equal "Hello, Ruby!", greeting
      end
    end
  end
end
