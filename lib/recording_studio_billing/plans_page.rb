# frozen_string_literal: true

module RecordingStudioBilling
  module PlansPage
    module_function

    def configured?
      host_url_helpers.respond_to?(RecordingStudioBilling.configuration.plans_page_route_helper)
    end

    def path_for(root_recording, url_helpers: host_url_helpers)
      helper = RecordingStudioBilling.configuration.plans_page_route_helper
      if configured?
        return url_helpers.public_send(helper, root_recording_id: root_recording.id)
      end

      billing_route_helpers(url_helpers).plan_billing_path(root_recording_id: root_recording.id)
    end

    def host_url_helpers
      Rails.application.routes.url_helpers
    end

    def billing_route_helpers(url_helpers)
      return url_helpers if url_helpers.respond_to?(:plan_billing_path)
      return url_helpers.recording_studio_billing if url_helpers.respond_to?(:recording_studio_billing)

      Engine.routes.url_helpers
    end
  end
end
