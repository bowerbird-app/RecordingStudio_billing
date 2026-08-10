# frozen_string_literal: true

module RecordingStudioBilling
  module Billable
    extend ActiveSupport::Concern

    included do |base|
      RecordingStudioBilling.register_capabilities!
      RecordingStudio.enable_capability(:billing, on: base)
      RecordingStudio.register_recordable_type(RecordingStudioBilling::Account)
    end
  end
end
