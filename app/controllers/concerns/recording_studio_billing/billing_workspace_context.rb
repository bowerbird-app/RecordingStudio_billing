# frozen_string_literal: true

module RecordingStudioBilling
  module BillingWorkspaceContext
    extend ActiveSupport::Concern

    included do
      helper RecordingStudioBilling::EngineRoutesHelper if defined?(RecordingStudioBilling::EngineRoutesHelper)
    end

    private

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

    def load_optional_root_recording!
      if billing_root_id.present? && current_billing_actor&.persisted?
        load_root_recording!
        return
      end

      @root_recording = nil
      @account_recording = nil
    end

    def billing_root_id
      selected_root = current_root_recording if respond_to?(:current_root_recording)
      selected_root&.id || session[:recording_studio_billing_root_recording_id] || params[:root_recording_id]
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

    def billing_presenter(page, **attributes)
      presenter_class = RecordingStudioBilling.configuration.billing_presenter_for(
        page, "RecordingStudioBilling::#{page.to_s.camelize}Presenter".constantize
      )
      presenter_class.new(root_recording:, **attributes)
    end

    def customer_offers_for(*kinds)
      CustomerOfferEligibility.call(root_recording:, account_recording:, kinds:)
    end

    def load_plans_presenter!
      subscriptions = root_recording ? Subscription.for_root(root_recording).order(created_at: :desc) : []
      eligible = if account_recording
                   customer_offers_for("plan")
                 else
                   []
                 end
      @presenter = billing_presenter(
        :plans,
        subscriptions:,
        account_recording:,
        eligible_options: eligible
      )
    end

    attr_reader :account_recording, :root_recording
  end
end
