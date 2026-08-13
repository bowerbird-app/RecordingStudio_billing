# frozen_string_literal: true

require "recording_studio_accessible"

module RecordingStudioBilling
  class ApplicationController < ActionController::Base
    include RecordingStudio::RootSwitchable::ControllerSupport if defined?(RecordingStudio::RootSwitchable::ControllerSupport)

    protect_from_forgery with: :exception
    layout "application"

    before_action :authenticate_billing_user!
    before_action :load_root_recording!

    private

    def authenticate_billing_user!
      return if respond_to?(:current_user) && current_user.present?

      redirect_to main_app.user_session_path
      false
    end

    def load_root_recording!
      selected_root = current_root_recording if respond_to?(:current_root_recording)
      root_id = selected_root&.id || session[:recording_studio_billing_root_recording_id]
      raise ActiveRecord::RecordNotFound if root_id.blank? ||
                                            (params[:root_recording_id].present? && params[:root_recording_id].to_s != root_id.to_s)

      @root_recording = RecordingStudio::Recording.find(root_id)
      raise ActiveRecord::RecordNotFound unless @root_recording.root_recording_id == @root_recording.id
      raise ActiveRecord::RecordNotFound if @root_recording.trashed_at?
      raise ActiveRecord::RecordNotFound if @root_recording.recordable.is_a?(RecordingStudioBilling::BillingAdmin)

      @account_recording = RecordingStudio::Recording.unscoped.find_by!(
        root_recording_id: @root_recording.id,
        parent_recording_id: @root_recording.id,
        recordable_type: "RecordingStudioBilling::Account"
      )
      raise ActiveRecord::RecordNotFound unless @account_recording.recordable.root_recording_id == @root_recording.id
      raise ActiveRecord::RecordNotFound if @account_recording.trashed_at?

      authorize_billing_action!(:view_billing)

      session[:recording_studio_billing_root_recording_id] = @root_recording.id
    end

    def current_billing_actor
      return current_user if respond_to?(:current_user) && current_user.present?

      Current.actor if defined?(Current)
    end

    def authorize_billing_action!(action)
      raise ActiveRecord::RecordNotFound unless current_billing_actor&.persisted?
      raise ActiveRecord::RecordNotFound unless RecordingStudioAccessible.authorized?(
        actor: current_billing_actor, recording: @root_recording, role: AccessActions.role_for(action)
      )
    end

    attr_reader :account_recording, :root_recording
  end
end
