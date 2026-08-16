# frozen_string_literal: true

module RecordingStudioBilling
  class SettingsPresenter < BasePresenter
    attr_accessor :account

    def page = :settings

    def notice
      if portal_available?
        copy("settings_portal_notice",
             "Payment methods, billing address, tax IDs, and invoice history are updated in the payment portal.")
      else
        copy("settings_notice", "Payment methods cannot be changed here yet.")
      end
    end

    def portal_available?
      RecordingStudioBilling.configuration.billing_portal_context_resolver.present?
    end
  end
end
