# frozen_string_literal: true

module RecordingStudioBilling
  module HostLayoutSupport
    extend ActiveSupport::Concern

    private

    def non_html_format?
      format = request&.format
      return false if format.nil?
      return false if format.html?
      return false if format.symbol == :all

      true
    end

    def host_layout?(name)
      return true if Rails.root.join("app/views/layouts/#{name}.html.erb").file?

      lookup_context.exists?(name, %w[layouts], false)
    rescue StandardError
      false
    end
  end
end
