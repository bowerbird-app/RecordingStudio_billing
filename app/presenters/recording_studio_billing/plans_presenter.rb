# frozen_string_literal: true

module RecordingStudioBilling
  class PlansPresenter < SubscriptionsPresenter
    def page = :plans

    def checkout_allowed?
      checkout_available?
    end

    def checkout_available?
      root_recording.present?
    end
  end
end
