# frozen_string_literal: true

module RecordingStudioBilling
  class BasePresenter
    attr_reader :root_recording

    def initialize(root_recording:, **attributes)
      @root_recording = root_recording
      attributes.each { |name, value| public_send("#{name}=", value) }
    end

    def copy(key, default)
      RecordingStudioBilling.configuration.billing_copy.fetch(key.to_s, default)
    end

    def support_url
      RecordingStudioBilling.configuration.support_url
    end

    def navigation_items
      RecordingStudioBilling.configuration.hooks.billing_navigation_items(self)
    end

    def page_contents(page)
      RecordingStudioBilling.configuration.hooks.billing_page_contents(page, self)
    end
  end
end
