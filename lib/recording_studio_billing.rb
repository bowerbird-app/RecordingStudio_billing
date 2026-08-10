# frozen_string_literal: true

require "recording_studio_billing/version"
require "recording_studio_billing/hooks"
require "recording_studio_billing/configuration"
require "recording_studio_billing/billable"
require "recording_studio_billing/billing_admin_support"
require "recording_studio_billing/engine"

module RecordingStudioBilling
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
    end

    def register_capabilities!
      return unless defined?(RecordingStudio)

      RecordingStudio.register_capability(
        :billing,
        source: "recording_studio_billing",
        child_recordables: "RecordingStudioBilling::Account"
      )
      RecordingStudio.register_capability(
        :billing_admin,
        source: "recording_studio_billing",
        child_recordables: "RecordingStudioBilling::BillingAdmin"
      )
    end
  end
end
