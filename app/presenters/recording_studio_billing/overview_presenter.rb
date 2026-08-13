# frozen_string_literal: true

module RecordingStudioBilling
  class OverviewPresenter < BasePresenter
    attr_accessor :subscriptions, :checkout_intents

    def page = :overview
  end
end
