# frozen_string_literal: true

require File.expand_path("../../../../app/services/recording_studio_billing/fake_financial_adapter", __dir__)

RecordingStudioBilling.configure do |config|
  config.provider = :fake
  config.commercial_authorizer = ->(**) { true }
end

RecordingStudioBilling.register_provider(:fake, RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success))
