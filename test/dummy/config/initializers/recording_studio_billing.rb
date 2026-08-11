# frozen_string_literal: true

RecordingStudioBilling.configure do |config|
  config.provider = :fake
  config.commercial_authorizer = ->(**) { true }
end
