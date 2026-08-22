# frozen_string_literal: true

require "recording_studio_accessible"

module RecordingStudioBilling
  module Billable
    extend ActiveSupport::Concern

    included do |base|
      RecordingStudioBilling.register_capabilities!
      RecordingStudio.enable_capability(:billing, on: base)
      RecordingStudio.enable_capability(:accessible, on: base)
    end
  end
end
