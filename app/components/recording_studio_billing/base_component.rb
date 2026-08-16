# frozen_string_literal: true

module RecordingStudioBilling
  class BaseComponent < ViewComponent::Base
    renders_many :header_extensions
    renders_many :body_extensions
    renders_many :footer_extensions

    def status_badge_style(state)
      case state.to_s
      when "Succeeded", "Applied", "Active", "Trial" then :success
      when "Failed", "Cancelled", "Past due" then :danger
      when "Scheduled" then :primary
      when "Waiting for confirmation", "Paused" then :warning
      else :default
      end
    end

    private

    def render_extension(content)
      content.respond_to?(:render_in) ? helpers.render(content) : content
    end
  end
end
