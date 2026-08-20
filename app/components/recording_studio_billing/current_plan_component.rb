# frozen_string_literal: true

module RecordingStudioBilling
  class CurrentPlanComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end

    def row
      @row ||= @presenter.subscription_rows.find { |item| item[:current] } || @presenter.subscription_rows.first
    end
  end
end
