# frozen_string_literal: true

module RecordingStudioBilling
  class BaseComponent < ViewComponent::Base
    include RecordingStudioBilling::EngineRoutesHelper

    renders_many :header_extensions
    renders_many :body_extensions
    renders_many :footer_extensions

    def status_badge_style(state)
      case state.to_s
      when "Succeeded", "Applied", "Active", "Trial", "Done", "Paid" then :success
      when "Failed", "Cancelled", "Past due" then :danger
      when "Scheduled" then :primary
      when "Waiting", "Waiting for confirmation", "Paused", "Needs a look" then :warning
      else :default
      end
    end

    private

    def render_extension(content)
      content.respond_to?(:render_in) ? helpers.render(content) : content
    end
  end
end
