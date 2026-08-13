# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionsPresenter < BasePresenter
    attr_accessor :subscriptions, :eligible_options

    def page = :subscriptions
  end
end
