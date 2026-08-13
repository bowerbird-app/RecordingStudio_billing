# frozen_string_literal: true

module RecordingStudioBilling
  class AdminOperationsController < ApplicationController
    include RecordingStudioAdmin::AdminActionAuditing

    class Context < RecordingStudioAdmin::Context
      def initialize(access_recording:, **attributes)
        super(**attributes)
        @access_recording = access_recording
      end

      attr_reader :access_recording

      def site_admin_recording = @access_recording
    end

    skip_before_action :load_root_recording!
    before_action :load_operation!
    before_action :load_billing_admin!
    before_action :authorize_operation!

    def perform
      perform_recording_studio_admin_action!(resource_key, action_key, operation_record) do
        dispatch_operation!
      end
      redirect_to recording_studio_admin_context.admin_screen_path(resource_key), notice: "Billing operation completed."
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      redirect_to recording_studio_admin_context.admin_screen_path(resource_key), alert: e.message
    end

    private

    def load_operation!
      @operation_record, @resource_key, @action_key = case params[:operation]
                                                      when "publish_price"
                                                        [Price.with_current_recording.find(params[:id]),
                                                         "billing_prices", :publish]
                                                      when "preview_plan_update"
                                                        [PlanUpdate.with_current_recording.find(params[:id]),
                                                         "billing_plan_updates", :preview]
                                                      when "confirm_plan_update"
                                                        [PlanUpdateRun.find(params[:id]), "billing_plan_update_runs",
                                                         :confirm]
                                                      when "apply_plan_update"
                                                        [PlanUpdateRun.find(params[:id]), "billing_plan_update_runs",
                                                         :apply]
                                                      when "reconcile_command"
                                                        [FinancialCommand.find(params[:id]),
                                                         "billing_financial_commands", :reconcile]
                                                      else
                                                        raise ActiveRecord::RecordNotFound
                                                      end
    end

    def load_billing_admin!
      root_id = case operation_record
                when Price, PlanUpdate then operation_record.recording.root_recording_id
                when PlanUpdateRun then operation_record.plan_update.recording.root_recording_id
                when FinancialCommand then operation_record.provider_account_recording&.root_recording_id
                end
      @billing_admin_recording = RecordingStudio::Recording.unscoped.find_by!(
        root_recording_id: root_id, recordable_type: "RecordingStudioBilling::BillingAdmin", trashed_at: nil
      )
    end

    def authorize_operation!
      RecordingStudioAdmin.authorize_resource!(
        key: resource_key, action: action_key, context: recording_studio_admin_context, record: operation_record, audit: true
      )
    rescue RecordingStudioAdmin::AuthorizationFailed, RecordingStudioAdmin::DefinitionNotFound
      head :forbidden
    end

    def dispatch_operation!
      case params[:operation]
      when "publish_price"
        CommercialPublisher.publish!(
          root_recording: billing_admin_recording.root_recording,
          price_recording_ids: [operation_record.recording.id], actor: current_billing_actor
        )
      when "preview_plan_update"
        ApplyPlanUpdate.call(plan_update: operation_record, root_recording: billing_admin_recording.root_recording,
                             idempotency_key: "admin-preview:#{operation_record.id}")
      when "confirm_plan_update"
        ApplyPlanUpdate.call(run: operation_record, root_recording: billing_admin_recording.root_recording,
                             confirmation: { "approved_by" => current_billing_actor.id.to_s },
                             idempotency_key: operation_record.idempotency_key)
      when "apply_plan_update"
        ApplyPlanUpdate.call(run: operation_record, root_recording: billing_admin_recording.root_recording,
                             confirmation: operation_record.confirmation, idempotency_key: operation_record.idempotency_key)
      when "reconcile_command"
        ReconcileProviderCommand.call(command: operation_record)
      end
    end

    def recording_studio_admin_context
      @recording_studio_admin_context ||= Context.new(
        access_recording: billing_admin_recording, params: params.to_unsafe_h, current_actor: current_billing_actor,
        controller: self, routes: self, view_context: view_context
      )
    end

    def current_root_recording = billing_admin_recording.root_recording

    attr_reader :action_key, :billing_admin_recording, :operation_record, :resource_key
  end
end
