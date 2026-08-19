# frozen_string_literal: true

module RecordingStudioBilling
  module EngineRoutesHelper
    def billing_route_helpers
      @billing_route_helpers ||= PlansPage.billing_route_helpers(helpers)
    end

    def plans_path_for(root_recording)
      PlansPage.path_for(root_recording)
    end
  end
end
