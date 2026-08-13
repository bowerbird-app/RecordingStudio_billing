# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionItem < RecordingStudioBilling::ApplicationRecord
    STATES = %w[active cancelled].freeze

    belongs_to :subscription
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    has_many :versions, class_name: "RecordingStudioBilling::SubscriptionItemVersion", dependent: :restrict_with_error

    validates :line_key, presence: true
    validates :state, inclusion: { in: STATES }
  end
end
