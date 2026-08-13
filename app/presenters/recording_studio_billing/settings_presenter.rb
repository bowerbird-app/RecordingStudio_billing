# frozen_string_literal: true

module RecordingStudioBilling
  class SettingsPresenter < BasePresenter
    attr_accessor :account

    def page = :settings

    def notice
      copy("settings_notice",
           "Payment methods and provider portal changes are disabled until a provider-authorized billing settings command is configured.")
    end
  end
end
