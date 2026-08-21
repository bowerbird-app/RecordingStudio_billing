# frozen_string_literal: true

RecordingStudioAdmin.configure do |config|
  config.engine_layout = "recording_studio/default_layout"
  config.authentication_method = :authenticate_user!
  config.current_actor_method = :current_user
  config.access_recording_resolver = lambda do |_context|
    admin_root = AdminRoot.find_by(name: "Billing Administration")
    next unless admin_root

    RecordingStudio.root_recording_for(admin_root)
  end
  config.site_admin_recording_resolver = config.access_recording_resolver
end

Rails.application.config.to_prepare do
  RecordingStudioAdmin::ApplicationController.helper ApplicationHelper
end
