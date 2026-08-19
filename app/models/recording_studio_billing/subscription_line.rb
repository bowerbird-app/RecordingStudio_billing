# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionLine < RecordingStudioBilling::ApplicationRecord
    recording_studio_recordable label: "Plan line", root: false,
                                allowed_parent_types: "RecordingStudioBilling::Subscription"

    MODES = %w[free_plan monthly_subscription annual_subscription trial_subscription recurring_addon].freeze
    STATES = %w[active cancelled].freeze
    SOURCE_TYPES = %w[checkout subscription_change].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :subscription_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :checkout_intent, optional: true
    belongs_to :product_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :billing_option_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :price_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    has_one :recording, as: :recordable, class_name: "RecordingStudio::Recording", dependent: :restrict_with_error

    scope :with_current_recording, -> { joins(:recording) }

    validates :mode, inclusion: { in: MODES }
    validates :state, inclusion: { in: STATES }
    validates :line_key, format: { with: /\A[0-9a-f-]{36}(?::[0-9a-f-]{36})?\z/ }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
    validates :source_type, inclusion: { in: SOURCE_TYPES }
    validate :safe_snapshot
    validate :line_identity_matches_mode

    def subscription
      subscription_recording&.recordable
    end

    # Same story as Subscription: a revised line leaves this row behind, so
    # follow (subscription recording, line key) forward to the live snapshot.
    def current
      self.class.with_current_recording.find_by(subscription_recording_id:, line_key:)
    end

    def current_recording
      current&.recording
    end

    private

    def safe_snapshot
      SafeFinancialPayload.validate!(commercial_snapshot)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:commercial_snapshot, e.message)
    end

    def line_identity_matches_mode
      expected = if mode == "recurring_addon"
                   "#{product_recording_id}:#{billing_option_recording_id}"
                 else
                   product_recording_id.to_s
                 end
      errors.add(:line_key, "must match the frozen subscription line identity") unless line_key == expected
    end
  end
end
