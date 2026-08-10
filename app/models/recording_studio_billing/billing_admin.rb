# frozen_string_literal: true

module RecordingStudioBilling
  class BillingAdmin < ApplicationRecord
    recording_studio_recordable label: "Billing administration", root: false

    validates :key, presence: true, uniqueness: true
  end
end
