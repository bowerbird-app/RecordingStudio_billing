# frozen_string_literal: true

module RecordingStudioBilling
  class UsagePresenter < BasePresenter
    attr_accessor :entitlements

    def page = :usage

    def credits
      entitlements.fetch("credits", {})
    end
  end
end
