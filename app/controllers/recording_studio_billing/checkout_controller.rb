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
      presentable = presentable_checkout_command?(command)
      # #region agent log
      begin
        require "json"
        File.open("/opt/cursor/logs/debug.log", "a") do |f|
          f.puts(JSON.generate({
                                 hypothesisId: "D", location: "checkout_controller.rb:checkout_presentation",
                                 message: "presentation gate",
                                 data: {
                                   intent_state: @checkout_intent.state, command_state: command&.state,
                                   has_provider_reference: command&.provider_reference?,
                                   checkout_session_created: checkout_session_created?(command),
                                   presentable: presentable, adapter_key: command&.provider_adapter_key
                                 },
                                 timestamp: (Time.now.to_f * 1000).to_i, runId: "post-fix"
                               }))
        end
      rescue StandardError
      end
      # #endregion
      return {} unless presentable

      adapter = RecordingStudioBilling.provider_adapter(command.provider_adapter_key)
      return {} unless adapter.respond_to?(:checkout_presentation)

      presentation = adapter.checkout_presentation(provider_reference: command.provider_reference)
      # #region agent log
      begin
        require "json"
        values = presentation.respond_to?(:to_h) ? presentation.to_h : {}
        File.open("/opt/cursor/logs/debug.log", "a") do |f|
          f.puts(JSON.generate({
                                 hypothesisId: "F", location: "checkout_controller.rb:checkout_presentation:result",
                                 message: "presentation returned",
                                 data: {
                                   mode: values[:mode] || values["mode"],
                                   has_client_secret: values[:client_secret].present? || values["client_secret"].present?,
                                   has_url: values[:url].present? || values["url"].present?,
                                   has_publishable_key: values[:publishable_key].present? || values["publishable_key"].present?,
                                   empty: values.empty?
                                 },
                                 timestamp: (Time.now.to_f * 1000).to_i, runId: "post-fix"
                               }))
        end
      rescue StandardError
      end
      # #endregion
      presentation
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
