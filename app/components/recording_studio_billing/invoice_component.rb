# frozen_string_literal: true

module RecordingStudioBilling
  class InvoiceComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end
  end
end
