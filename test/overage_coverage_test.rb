# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class OverageCoverageTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup { BillingTestDatabaseCleanup.clear! }
  teardown { BillingTestDatabaseCleanup.clear! }

  test "rejects caller-authoritative rate hashes" do
    assert_raises(ArgumentError) do
      RecordingStudioBilling.calculate_overage(
        allocation: Object.new, rate: { "amount_minor" => 1, "package_size" => 0, "currency_code" => "USD",
                                        "currency_exponent" => 2 }
      )
    end
  end
end
