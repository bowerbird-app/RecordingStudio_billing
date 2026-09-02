# frozen_string_literal: true

module RecordingStudioBilling
  class AdminPageController < ApplicationController
    skip_before_action :load_root_recording!

    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from RecordingStudioAdmin::AuthorizationFailed,
                RecordingStudioAdmin::DefinitionNotFound,
                with: :render_forbidden

    private

    def render_billing_admin_page(page_key)
      @billing_admin_page_key = page_key
      @billing_admin_page_scope = BillingAdminForms.scope_for!(
        page_key: page_key,
        parent_recording_id: params[:parent_recording_id],
        id: params[:id]
      )
      @page = BillingAdminForms.page!(
        page_key: page_key,
        scope: @billing_admin_page_scope,
        context: recording_studio_admin_context,
        return_to: params[:return_to]
      )
    end

    def recording_studio_admin_context
      @recording_studio_admin_context ||= RecordingStudioAdmin::Context.new(
        params: params.to_unsafe_h,
        current_actor: current_billing_actor,
        controller: self,
        routes: self,
        view_context: view_context,
        surface: billing_admin_page_surface
      )
    end

    def billing_admin_page_surface
      access_recording = @billing_admin_page_scope.access_recording
      surface_key = BillingAdminForms.definition_for(@billing_admin_page_key).fetch(:surface)
      RecordingStudioAdmin::Surface.new(
        surface_key,
        access_recording_resolver: ->(_context) { access_recording }
      )
    end

    def render_not_found
      head :not_found
    end

    def render_forbidden
      head :forbidden
    end
  end
end
