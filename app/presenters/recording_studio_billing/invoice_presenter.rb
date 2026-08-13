# frozen_string_literal: true

module RecordingStudioBilling
  class InvoicePresenter < BasePresenter
    attr_accessor :invoice

    def page = :invoice
  end
end
