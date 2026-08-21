# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutSelectionsController < ApplicationController
    before_action -> { authorize_billing_action!(:start_checkout) }

    def create
      # #region agent log
      selection = checkout_selection
      host = trusted_host_country
      begin
        require "json"
        File.open("/opt/cursor/logs/debug.log", "a") do |f|
          f.puts(JSON.generate({ hypothesisId: "A", location: "checkout_selections_controller.rb:create", message: "selection parsed", data: { country_code: selection[:country_code], currency_code: selection[:currency_code], presentation: selection[:presentation], item_count: selection[:items]&.size, request_key_len: selection[:request_key].to_s.length, root_id: root_recording&.id, host_country_present: !host.nil?, host_country_class: host.class.name }, timestamp: (Time.now.to_f * 1000).to_i, runId: "post-fix" }))
        end
      rescue StandardError
      end
      # #endregion
      result = RecordingStudioBilling.create_checkout_intent(
        root_recording: root_recording,
        local_idempotency_key: "customer-checkout:#{selection.fetch(:request_key)}",
        items: selection.fetch(:items),
        country_code: selection[:country_code],
        currency_code: selection[:currency_code],
        presentation: selection[:presentation],
        host_country: host
      )
      raise ArgumentError, "checkout request conflicts with existing selection" if result.conflict?

      # #region agent log
      begin
        require "json"
        File.open("/opt/cursor/logs/debug.log", "a") do |f|
          f.puts(JSON.generate({ hypothesisId: "A", location: "checkout_selections_controller.rb:create:success", message: "intent created", data: { intent_id: result.intent.id, status: result.status.to_s, intent_state: result.intent.state, adapter: result.intent.financial_command&.provider_adapter_key }, timestamp: (Time.now.to_f * 1000).to_i, runId: "post-fix" }))
        end
      rescue StandardError
      end
      # #endregion
      redirect_to checkout_path(result.intent, root_recording_id: root_recording.id)
    rescue ActiveRecord::RecordNotFound, ArgumentError, ActionController::ParameterMissing => error
      # #region agent log
      begin
        require "json"
        File.open("/opt/cursor/logs/debug.log", "a") do |f|
          f.puts(JSON.generate({ hypothesisId: "A", location: "checkout_selections_controller.rb:create:rescue", message: "create failed closed", data: { error_class: error.class.name, error_message: error.message }, timestamp: (Time.now.to_f * 1000).to_i, runId: "post-fix" }))
        end
      rescue StandardError
      end
      # #endregion
      redirect_back fallback_location: RecordingStudioBilling::PlansPage.path_for(root_recording),
                    alert: "That billing selection is not currently available."
    end

    private

    def trusted_host_country
      context = RecordingStudioBilling.configuration.billing_location_context_resolver&.call(
        root_recording: root_recording
      )
      context.to_h[:host_country]
    rescue StandardError
      nil
    end

    def checkout_selection
      items = params.require(:items)
      raise ArgumentError, "checkout items must be an object" unless items.respond_to?(:each_value)
      raise ArgumentError, "checkout items must be present" if items.empty?

      normalized_items = items.each_value.map { |item| normalize_item(item) }
      option_ids = normalized_items.pluck("billing_option_recording_id")
      raise ArgumentError, "checkout options must be unique" unless option_ids.uniq.size == option_ids.size

      request_key = params.require(:checkout_request_key).to_s
      raise ArgumentError, "checkout request key is invalid" unless request_key.match?(/\A[0-9a-f]{32}\z/)

      permitted = params.permit(:country_code, :currency_code, :presentation)
      {
        request_key:,
        country_code: permitted[:country_code],
        currency_code: permitted[:currency_code],
        presentation: permitted[:presentation],
        items: normalized_items
      }
    end

    def normalize_item(item)
      raise ArgumentError, "checkout item is invalid" unless item.respond_to?(:to_unsafe_h)

      attributes = item.to_unsafe_h.stringify_keys
      allowed = %w[billing_option_recording_id quantity]
      raise ArgumentError, "checkout item contains unsupported input" unless (attributes.keys - allowed).empty?
      raise ArgumentError, "checkout option is missing" if attributes["billing_option_recording_id"].blank?

      if attributes["quantity"].present?
        raise ArgumentError, "checkout quantity is invalid" unless attributes["quantity"].to_s.match?(/\A\d+\z/)

        attributes["quantity"] = attributes["quantity"].to_i
      end

      attributes.slice(*allowed)
    end
  end
end
