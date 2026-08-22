# frozen_string_literal: true

RecordingStudioAdmin.configure do |config|
  config.engine_layout = "recording_studio/default_layout"
  config.authentication_method = :authenticate_user!
  config.current_actor_method = :current_user

  site_admin_recording = lambda do
    admin_root = AdminRoot.find_by(name: "Billing Administration")
    next unless admin_root

    RecordingStudio.root_recording_for(admin_root)
  end

  config.access_recording_resolver = lambda do |context|
    controller = context.controller
    if controller.is_a?(RecordingStudioBilling::AdminOperationsController)
      next controller.send(:recording_studio_admin_access_recording)
    end

    site_admin_recording.call
  end
  config.site_admin_recording_resolver = ->(_context) { site_admin_recording.call }
end

Rails.application.config.to_prepare do
  RecordingStudioAdmin::ApplicationController.helper ApplicationHelper
end
