# frozen_string_literal: true

module RecordingStudioBilling
  class AddonsPresenter < BasePresenter
    attr_accessor :purchases, :eligible_options

    def page = :addons
  end
end
