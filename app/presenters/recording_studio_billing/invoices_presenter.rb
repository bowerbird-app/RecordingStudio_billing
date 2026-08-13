# frozen_string_literal: true

module RecordingStudioBilling
  class InvoicesPresenter < BasePresenter
    attr_accessor :invoices, :adjustments

    def page = :invoices
  end
end
