# frozen_string_literal: true

# Ensure mounted Recording Studio screens use the shared default layout contract.
Rails.application.config.to_prepare do
  RecordingStudio::ApplicationController.include(RecordingStudio::UsesDefaultLayout)
end
