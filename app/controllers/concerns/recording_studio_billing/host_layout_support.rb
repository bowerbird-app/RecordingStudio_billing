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
  end
end
