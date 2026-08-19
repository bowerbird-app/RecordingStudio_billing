# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionsController < ApplicationController
    before_action :load_subscription
    before_action :authorize_subscription_action!

    def cancel_confirmation
      @presenter = subscription_change_presenter(:cancellation)
    end

    def cancel
      create_change!("cancellation")
    end

    def resume_confirmation
      @presenter = subscription_change_presenter(:resumption)
    end

    def resume
      create_change!("resumption")
    end

    def change_selection
      @presenter = subscription_change_presenter(:selection, eligible_options: change_options)
    end

    def compare_change
      request = comparison_request
      proposal = ResolveSubscriptionChangeProposal.call(
        subscription: @subscription, root_recording:, billing_option_recording_id: request.fetch("billing_option_recording_id"),
        quantity: request["quantity"], change_kind: request.fetch("change_kind")
      )
      proposal_key = SecureRandom.hex(16)
      comparison_proposals[proposal_key] = request.merge(
        "root_recording_id" => root_recording.id, "account_recording_id" => account_recording.id,
        "subscription_recording_id" => @subscription_recording.id, "manifest_digest" => proposal.manifest_digest,
        "provider_root_recording_id" => proposal.root_recording_id, "current_manifest_digests" => current_manifest_digests,
        "expires_at" => 15.minutes.from_now.to_i
      )
      @presenter = subscription_change_presenter(request.fetch("change_kind").to_sym, proposal:,
                                                                                      request_key: proposal_key)
      render :change_comparison
    rescue ActiveRecord::RecordNotFound, ArgumentError, ActionController::ParameterMissing
      redirect_to change_selection_subscription_path(@subscription, root_recording_id: root_recording.id),
                  alert: "That subscription change is unavailable."
    end

    def confirm_change
      stored = comparison_proposal!
      if stored["intent_id"].present?
        intent = SubscriptionChangeIntent.where(root_recording:, account_recording:,
                                                subscription_recording: @subscription_recording).find(stored.fetch("intent_id"))
        return redirect_to subscription_change_path(intent, root_recording_id: root_recording.id)
      end

      proposal = ResolveSubscriptionChangeProposal.call(
        subscription: @subscription, root_recording:, billing_option_recording_id: stored.fetch("billing_option_recording_id"),
        quantity: stored["quantity"], change_kind: stored.fetch("change_kind")
      )
      unless proposal.manifest_digest == stored.fetch("manifest_digest") &&
             proposal.root_recording_id == stored.fetch("provider_root_recording_id") &&
             current_manifest_digests == stored.fetch("current_manifest_digests")
        raise ArgumentError,
              "subscription proposal changed"
      end

      manifest = proposal.persist_and_mark_used!
      result = RecordingStudioBilling.create_subscription_change_intent(
        subscription: @subscription, root_recording:, local_idempotency_key: "customer-change:#{confirmation_params.fetch(:proposal_key)}",
        change_kind: stored.fetch("change_kind"), change_set: stored.slice("billing_option_recording_id", "quantity"),
        proposed_manifest: manifest
      )
      raise ArgumentError, "subscription change conflicts with an existing request" if result.conflict?

      stored["intent_id"] = result.intent.id
      stored["used_at"] = Time.current.to_i
      comparison_proposals[confirmation_params.fetch(:proposal_key).to_s] = stored

      redirect_to subscription_change_path(result.intent, root_recording_id: root_recording.id)
    rescue ActiveRecord::RecordNotFound, ArgumentError, ActionController::ParameterMissing
      redirect_to change_selection_subscription_path(@subscription, root_recording_id: root_recording.id),
                  alert: "That subscription change could not be requested."
    end

    private

    def load_subscription
      @subscription = Subscription.for_root(root_recording).find(params[:id])
      @subscription_recording = @subscription.recording
    end

    def create_change!(kind)
      result = RecordingStudioBilling.create_subscription_change_intent(
        subscription: @subscription,
        root_recording: root_recording,
        local_idempotency_key: "customer-#{kind}:#{@subscription_recording.id}:#{@subscription.updated_at.to_i}",
        change_kind: kind
      )
      redirect_to subscription_change_path(result.intent, root_recording_id: root_recording.id),
                  notice: "Subscription change requested."
    rescue ArgumentError
      raise ActiveRecord::RecordNotFound
    end

    def subscription_change_presenter(kind, **attributes)
      presenter_class = RecordingStudioBilling.configuration.billing_presenter_for(
        :subscription_change, RecordingStudioBilling::SubscriptionChangePresenter
      )
      presenter_class.new(root_recording:, subscription: @subscription, change_kind: kind, **attributes)
    end

    def authorize_subscription_action!
      action = if action_name.start_with?("cancel")
                 :cancel_subscription
               elsif action_name.start_with?("resume")
                 :resume_subscription
               else
                 :request_subscription_change
               end
      authorize_billing_action!(action)
    end

    def change_options
      CustomerOfferEligibility.call(root_recording:, account_recording:, kinds: %w[plan addon])
    end

    def comparison_params
      params.require(:subscription_change).permit(:change_kind, :billing_option_recording_id, :quantity, :proposal_key)
    end

    def confirmation_params
      params.require(:subscription_change).permit(:proposal_key)
    end

    def comparison_request
      values = comparison_params.slice(:change_kind, :billing_option_recording_id, :quantity).to_h.stringify_keys
      raise ActionController::ParameterMissing, :change_kind unless ResolveSubscriptionChangeProposal::KINDS.include?(values["change_kind"])

      if values["billing_option_recording_id"].blank?
        raise ActionController::ParameterMissing,
              :billing_option_recording_id
      end

      values
    end

    def comparison_proposals
      session[:recording_studio_billing_subscription_change_proposals] ||= {}
    end

    def comparison_proposal!
      key = confirmation_params.fetch(:proposal_key).to_s
      proposal = comparison_proposals[key]
      unless proposal.is_a?(Hash) && proposal["expires_at"].to_i >= Time.current.to_i
        raise ArgumentError,
              "subscription proposal is unavailable"
      end

      expected = { "root_recording_id" => root_recording.id, "account_recording_id" => account_recording.id,
                   "subscription_recording_id" => @subscription_recording.id }
      unless expected.all? do |attribute, value|
        proposal[attribute] == value
      end
        raise ArgumentError,
              "subscription proposal does not match this account"
      end

      proposal
    end

    def current_manifest_digests
      @subscription.active_lines.pluck(:manifest_digest).sort
    end
  end
end
