# frozen_string_literal: true

class AdminRoot < ApplicationRecord
  include RecordingStudio::Recordable
  include RecordingStudioBilling::BillingAdminSupport

  recording_studio_recordable label: "Admin", root: true

  validates :name, presence: true
end
