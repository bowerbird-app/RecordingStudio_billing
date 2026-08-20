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
      return {} unless @checkout_intent.state == "awaiting_confirmation" && command&.provider_reference?

      adapter = RecordingStudioBilling.provider_adapter(command.provider_adapter_key)
      return {} unless adapter.respond_to?(:checkout_presentation)

      adapter.checkout_presentation(provider_reference: command.provider_reference)
    end

    def checkout_presenter(presentation)
      presenter_class = RecordingStudioBilling.configuration.billing_presenter_for(
        :checkout, RecordingStudioBilling::CheckoutPresenter
      )
      presenter_class.new(root_recording:, checkout_intent: @checkout_intent, presentation:)
    end
  end
end
