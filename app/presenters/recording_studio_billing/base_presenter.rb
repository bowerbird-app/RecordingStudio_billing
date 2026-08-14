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

    def display_amount(amount_minor, currency_code)
      [amount_minor, currency_code].compact.join(" ")
    end

    def display_value(value)
      case value
      when Hash
        value.map { |key, nested_value| "#{key.to_s.humanize}: #{display_value(nested_value)}" }.join(", ")
      when Array
        value.map { |nested_value| display_value(nested_value) }.join(", ")
      when nil
        nil
      else
        value.to_s
      end
    end

    def snapshot_value(snapshot, *keys)
      keys.reduce(snapshot || {}) { |value, key| value.is_a?(Hash) ? value[key.to_s] || value[key.to_sym] : nil }
    end
  end
end
