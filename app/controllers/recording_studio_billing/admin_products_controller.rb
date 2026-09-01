# frozen_string_literal: true

module RecordingStudioBilling
  class AdminProductsController < ApplicationController
    skip_before_action :load_root_recording!
    before_action :load_new_product_scope!

    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from RecordingStudioAdmin::AuthorizationFailed,
                RecordingStudioAdmin::DefinitionNotFound,
                with: :render_forbidden

    def new
      @page = BillingAdminProductNew.page!(
        scope: @new_product_scope,
        context: recording_studio_admin_context,
        return_to: params[:return_to]
      )
    end

    private

    def load_new_product_scope!
      @new_product_scope = BillingAdminProductNew.scope!(
        parent_recording_id: params[:parent_recording_id]
      )
    end

    def recording_studio_admin_context
      @recording_studio_admin_context ||= RecordingStudioAdmin::Context.new(
        params: params.to_unsafe_h,
        current_actor: current_billing_actor,
        controller: self,
        routes: self,
        view_context: view_context,
        surface: new_product_admin_surface
      )
    end

    def new_product_admin_surface
      default = RecordingStudioAdmin.configuration.default_surface
      access_recording = @new_product_scope.access_recording
      RecordingStudioAdmin::Surface.new(
        "billing_product_new",
        path: default.path,
        root_section: default.root_section,
        authentication_method: default.authentication_method,
        current_actor_method: default.current_actor_method,
        access_recording_method: default.access_recording_method,
        engine_layout: default.engine_layout,
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
