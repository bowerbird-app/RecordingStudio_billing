# frozen_string_literal: true

module RecordingStudioBilling
  class PlanRequestsComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end

    def request_badge_style(state)
      case state.to_s
      when "Succeeded", "Applied" then :success
      when "Failed" then :danger
      when "Scheduled" then :primary
      when "Waiting for confirmation" then :warning
      else :default
      end
    end
  end
end
