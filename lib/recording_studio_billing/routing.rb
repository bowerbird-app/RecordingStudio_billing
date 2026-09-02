# frozen_string_literal: true

module RecordingStudioBilling
  module Routing
    def draw_recording_studio_billing_plans(path: "/plans", as: :plans)
      get path, to: "recording_studio_billing/plans#show", as:
    end

    def draw_recording_studio_billing_admin(path: "/admin/billing", admin_path: "/admin")
      get path, to: redirect("#{admin_path.to_s.chomp('/')}/sections/billing")
    end
  end
end

ActionDispatch::Routing::Mapper.prepend(RecordingStudioBilling::Routing)
