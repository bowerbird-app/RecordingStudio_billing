# frozen_string_literal: true

module RecordingStudioBilling
  class PlanRequestsComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end

    def request_badge_style(state)
      status_badge_style(state)
    end
  end
end
