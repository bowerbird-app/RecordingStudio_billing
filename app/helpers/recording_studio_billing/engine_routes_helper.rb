# frozen_string_literal: true

module RecordingStudioBilling
  module EngineRoutesHelper
    def billing_route_helpers
      @billing_route_helpers ||= PlansPage.billing_route_helpers(helpers)
    end

    def plans_path_for(root_recording)
      PlansPage.path_for(root_recording)
    end

    def billing_overview_path_for(root_recording = nil)
      root_recording ||= @presenter.root_recording if @presenter.respond_to?(:root_recording)
      return root_path if root_recording.blank?

      root_path(root_recording_id: root_recording.id)
    end

    def billing_page_nav(title:, back_url: nil, back_label: nil)
      return unless respond_to?(:recording_studio_page_nav)

      recording_studio_page_nav(
        title: title,
        page_nav_back_url: back_url || main_app.root_path,
        page_nav_back_label: back_label || (back_url ? "Billing" : "Home"),
        page_nav_anchor_url: main_app.root_path,
        page_nav_anchor_label: "Close"
      )
    end
  end
end
