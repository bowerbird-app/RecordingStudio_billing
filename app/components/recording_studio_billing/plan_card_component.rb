# frozen_string_literal: true

module RecordingStudioBilling
  class PlanCardComponent < BaseComponent
    def initialize(plan:, presenter:)
      super()
      @plan = plan
      @presenter = presenter
    end
  end
end
