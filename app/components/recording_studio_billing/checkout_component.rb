# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end

    private

    attr_reader :presenter
  end
end
