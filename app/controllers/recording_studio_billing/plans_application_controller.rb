# frozen_string_literal: true

require "recording_studio_accessible"

module RecordingStudioBilling
  class PlansApplicationController < ActionController::Base
    include RecordingStudio::RootSwitchable::ControllerSupport if defined?(RecordingStudio::RootSwitchable::ControllerSupport)
    include RecordingStudio::UsesDefaultLayout if defined?(RecordingStudio::UsesDefaultLayout)
    include Devise::Controllers::Helpers if defined?(Devise::Controllers::Helpers)
    include BillingWorkspaceContext
    include HostLayoutSupport

    protect_from_forgery with: :exception
    layout :plans_host_layout
    helper RecordingStudioBilling::EngineRoutesHelper

    before_action :authenticate_billing_user!, if: :plans_page_requires_sign_in?
    before_action :load_plans_root_recording!

    private

    def plans_page_requires_sign_in?
      RecordingStudioBilling.configuration.plans_page_requires_sign_in
    end

    def load_plans_root_recording!
      if plans_page_requires_sign_in?
        load_root_recording!
      else
        load_optional_root_recording!
      end
    end

    def plans_host_layout
      return "application" if non_html_format?

      "recording_studio/default_layout"
    end

    def authenticate_billing_user!
      return if respond_to?(:current_user) && current_user.present?

      redirect_to main_app.user_session_path
      false
    end
  end
end
