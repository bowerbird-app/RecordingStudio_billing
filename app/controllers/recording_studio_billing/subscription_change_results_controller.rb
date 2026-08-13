# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionChangeResultsController < ApplicationController
    before_action -> { authorize_billing_action!(:view_billing) }

    def show
      @intent = SubscriptionChangeIntent.where(root_recording:, account_recording:).find(params[:id])
      presenter_class = RecordingStudioBilling.configuration.billing_presenter_for(
        :subscription_change, RecordingStudioBilling::SubscriptionChangePresenter
      )
      @presenter = presenter_class.new(root_recording:, subscription: @intent.subscription,
                                       change_kind: @intent.change_kind.to_sym, intent: @intent)
    end
  end
end
