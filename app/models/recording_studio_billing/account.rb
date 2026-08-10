# frozen_string_literal: true

module RecordingStudioBilling
  class Account < ApplicationRecord
    recording_studio_recordable label: "Billing account", root: false

    validates :name, presence: true
  end
end
