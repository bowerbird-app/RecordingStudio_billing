# frozen_string_literal: true

module RecordingStudioBilling
  module BillingAdminSupport
    extend ActiveSupport::Concern

    included do |base|
      raise LoadError, "recording_studio_admin is required to enable billing admin sections" unless defined?(RecordingStudioAdmin::AllowsAdminSections)

      base.include RecordingStudioAdmin::AllowsAdminSections
      RecordingStudioBilling.register_capabilities!
      RecordingStudio.enable_capability(:billing_admin, on: base)
      RecordingStudioAdmin.configuration.site_admin_recording_resolver ||= lambda do |context|
        recording = context.access_recording
        recordable = recording&.recordable
        recording if recordable && RecordingStudio.capability_enabled?(:billing_admin, for: recordable.class)
      end

      base.recording_studio_admin_sections do
        section :billing_commercial
        section :billing_financial
        section :billing_operations
      end
    end
  end
end
