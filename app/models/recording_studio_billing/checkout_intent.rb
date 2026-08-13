# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutIntent < RecordingStudioBilling::ApplicationRecord
    STATES = %w[draft validated awaiting_confirmation pending_provider requires_requote completed failed cancelled
                expired requires_review].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :financial_command, optional: true, inverse_of: false
    has_many :items, class_name: "RecordingStudioBilling::CheckoutIntentItem", dependent: :restrict_with_error
    has_many :attempts, class_name: "RecordingStudioBilling::CheckoutAttempt", dependent: :restrict_with_error

    validates :local_idempotency_key, :request_fingerprint, presence: true
    validates :request_fingerprint, format: { with: /\A\h{64}\z/ }
    validates :state, inclusion: { in: STATES }
    validate :direct_account_ownership

    def self.for_root(root_recording)
      root = RecordingStudio.root_recording_or_self(root_recording)
      where(root_recording_id: root.id)
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
