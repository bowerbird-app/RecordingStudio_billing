# frozen_string_literal: true

module RecordingStudioBilling
  class PaymentsComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end
  end
end
