# frozen_string_literal: true

module RecordingStudioBilling
  class SettingsPresenter < BasePresenter
    attr_accessor :account

    def page = :settings

    def notice
      copy("settings_notice",
           "Payment methods cannot be changed here yet.")
    end
  end
end
