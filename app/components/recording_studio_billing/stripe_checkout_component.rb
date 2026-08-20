# frozen_string_literal: true

module RecordingStudioBilling
  class StripeCheckoutComponent < CheckoutComponent
    def embedded_checkout_ready?
      presenter.embedded? && presentation_value(:client_secret).present? &&
        presentation_value(:publishable_key).present?
    end

    private

    attr_reader :presenter

    def presentation_value(key)
      presenter.presentation[key] || presenter.presentation[key.to_s]
    end
  end
end
