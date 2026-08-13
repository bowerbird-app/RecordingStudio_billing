# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end
  end
end
