# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutController < ApplicationController
    before_action :load_intent
    before_action -> { authorize_billing_action!(:view_checkout) }

    def show
      @presenter = checkout_presenter(checkout_presentation)
    end

    # A browser return is informative only. Provider webhook/reconciliation work
    # remains the sole path that can complete a CheckoutIntent.
    def return
      @presenter = checkout_presenter({})
      render :show
    end

    private

    def load_intent
      @checkout_intent = CheckoutIntent.for_root(root_recording).find(params[:id])
    end

    def checkout_presentation
      command = @checkout_intent.financial_command
      return {} unless presentable_checkout_command?(command)

      adapter = RecordingStudioBilling.provider_adapter(command.provider_adapter_key)
      return {} unless adapter.respond_to?(:checkout_presentation)

      adapter.checkout_presentation(provider_reference: command.provider_reference)
    end

    # Stripe creates a Checkout Session with status=pending and leaves the intent
    # in pending_provider until payment is confirmed. Presentation must still be
    # available so the browser can mount the session while confirmation is pending.
    def presentable_checkout_command?(command)
      return false unless command&.provider_reference?
      return true if @checkout_intent.state == "awaiting_confirmation"
      return true if @checkout_intent.state == "pending_provider" && checkout_session_created?(command)

      false
    end

    def checkout_session_created?(command)
      command&.normalized_result.to_h["checkout_session_created"] == true
    end

    def checkout_presenter(presentation)
      presenter_class = RecordingStudioBilling.configuration.billing_presenter_for(
        :checkout, RecordingStudioBilling::CheckoutPresenter
      )
      presenter_class.new(root_recording:, checkout_intent: @checkout_intent, presentation:)
    end
  end
end
