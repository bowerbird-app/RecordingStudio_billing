# frozen_string_literal: true

module RecordingStudioBilling
  module BillingAdminSupport
    extend ActiveSupport::Concern

    included do |base|
      unless defined?(RecordingStudioAdmin::AllowsAdminSections)
        raise LoadError, "recording_studio_admin is required to enable billing admin sections"
      end

      base.include RecordingStudioAdmin::AllowsAdminSections
      RecordingStudioBilling.register_capabilities!
      RecordingStudio.enable_capability(:billing_admin, on: base)
      RecordingStudio.register_recordable_type(RecordingStudioBilling::BillingAdmin)

      base.recording_studio_admin_sections do
        section :billing
      end
    end
  end
end
