# frozen_string_literal: true

module RecordingStudioBilling
  class BillingOverviewComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end
  end
end
