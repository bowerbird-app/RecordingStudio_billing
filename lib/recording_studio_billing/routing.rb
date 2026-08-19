# frozen_string_literal: true

module RecordingStudioBilling
  module Routing
    def draw_recording_studio_billing_plans(path: "/plans", as: :plans)
      get path, to: "recording_studio_billing/plans#show", as:
    end
  end
end

ActionDispatch::Routing::Mapper.prepend(RecordingStudioBilling::Routing)
