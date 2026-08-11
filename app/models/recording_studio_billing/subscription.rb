# frozen_string_literal: true

module RecordingStudioBilling
  class Subscription < RecordingStudioBilling::ApplicationRecord
    STATES = %w[trialing active past_due paused cancelled expired].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    has_many :item_versions, class_name: "RecordingStudioBilling::SubscriptionItemVersion", dependent: :restrict_with_error

    validates :identifier, presence: true, uniqueness: true
    validates :state, inclusion: { in: STATES }
    validates :provider_reference, length: { maximum: 512 }, allow_nil: true
    validate :direct_account_ownership

    def self.for_root(root_recording)
      where(root_recording_id: RecordingStudio.root_recording_or_self(root_recording).id)
    end

    private

    def direct_account_ownership
      account = account_recording
      valid = root_recording && account && account.recordable_type == "RecordingStudioBilling::Account" &&
              account.root_recording_id == root_recording.id && account.parent_recording_id == root_recording.id &&
              account.recordable.root_recording_id == root_recording.id
      errors.add(:account_recording, "must belong directly to the normalized root") unless valid
    end
  end
end