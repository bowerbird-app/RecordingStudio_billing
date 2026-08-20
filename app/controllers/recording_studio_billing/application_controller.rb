# frozen_string_literal: true

require "recording_studio_accessible"

module RecordingStudioBilling
  class ApplicationController < ActionController::Base
    include RecordingStudio::RootSwitchable::ControllerSupport if defined?(RecordingStudio::RootSwitchable::ControllerSupport)
    include Devise::Controllers::Helpers if defined?(Devise::Controllers::Helpers)
    include BillingWorkspaceContext
    include HostLayoutSupport

    protect_from_forgery with: :exception
    layout :billing_host_layout
    helper RecordingStudioBilling::EngineRoutesHelper

    before_action :authenticate_billing_user!
    before_action :load_root_recording!

    private

    def billing_host_layout
      return "application" if non_html_format?

      if host_layout?("recording_studio/default_layout")
        "recording_studio/default_layout"
      elsif host_layout?("flat_pack_sidebar")
        "flat_pack_sidebar"
      else
        "application"
      end
    end

    def authenticate_billing_user!
      return if respond_to?(:current_user) && current_user.present?

      redirect_to main_app.user_session_path
      false
    end
  end
end
