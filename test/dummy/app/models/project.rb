# frozen_string_literal: true

class Project < ApplicationRecord
  recording_studio_recordable label: "Project", root: false, allowed_parent_types: ["Workspace"]

  has_one :recording, as: :recordable, class_name: "RecordingStudio::Recording", dependent: :restrict_with_error

  scope :with_current_recording, -> { joins(:recording) }

  validates :name, presence: true

  class << self
    def for_root(root)
      root = RecordingStudio.root_recording_or_self(root)
      with_current_recording.where(recording_studio_recordings: { root_recording_id: root.id })
    end
  end
end
