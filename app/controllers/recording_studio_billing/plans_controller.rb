# frozen_string_literal: true

module RecordingStudioBilling
  class PlansController < PlansApplicationController
    def show
      load_plans_presenter!
    end
  end
end
