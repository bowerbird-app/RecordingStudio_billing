# frozen_string_literal: true

module RecordingStudioBilling
  class Account < RecordingStudioBilling::ApplicationRecord
    recording_studio_recordable label: "Billing account", root: false

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    has_one :recording, as: :recordable, class_name: "RecordingStudio::Recording", dependent: :restrict_with_error

    validates :name, presence: true
    validate :root_recording_is_a_root

    class << self
      def ensure_account(root_recording:, name: "Billing account")
        EnsureAccount.call(root_recording: root_recording, name: name)
      end
    end

    private

    def root_recording_is_a_root
      return if root_recording.blank?
      return if root_recording.parent_recording_id.blank? && root_recording.root_recording_id == root_recording.id

      errors.add(:root_recording, "must be a root Recording")
    end
  end
end
