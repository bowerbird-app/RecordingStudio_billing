# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutSelectionsController < ApplicationController
    before_action -> { authorize_billing_action!(:start_checkout) }

    def create
      result = RecordingStudioBilling.create_checkout_intent(
        root_recording: root_recording,
        local_idempotency_key: "customer-checkout:#{checkout_selection.fetch(:request_key)}",
        items: checkout_selection.fetch(:items),
        country_code: checkout_selection[:country_code],
        currency_code: checkout_selection[:currency_code],
        presentation: checkout_selection[:presentation]
      )
      raise ArgumentError, "checkout request conflicts with existing selection" if result.conflict?

      redirect_to checkout_path(result.intent, root_recording_id: root_recording.id)
    rescue ActiveRecord::RecordNotFound, ArgumentError, ActionController::ParameterMissing
      redirect_back fallback_location: plan_billing_path(root_recording_id: root_recording.id),
                    alert: "That billing selection is not currently available."
    end

    private

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
