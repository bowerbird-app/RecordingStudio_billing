# frozen_string_literal: true

module RecordingStudioBilling
  class PaymentsPresenter < BasePresenter
    attr_accessor :payments, :refunds

    def page = :payments
  end
end
