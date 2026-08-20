class Workspace < ApplicationRecord
  include RecordingStudioBilling::Billable

  recording_studio_recordable label: "Workspace", root: true

  validates :name, presence: true
end
