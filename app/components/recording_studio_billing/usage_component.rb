# frozen_string_literal: true

module RecordingStudioBilling
  class UsageComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end
  end
end
