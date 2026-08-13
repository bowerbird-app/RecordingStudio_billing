# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionItemVersion < RecordingStudioBilling::ApplicationRecord
    MODES = %w[free_plan monthly_subscription annual_subscription trial_subscription recurring_addon].freeze

    belongs_to :subscription
    belongs_to :subscription_item
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :checkout_intent, optional: true

    validates :mode, inclusion: { in: MODES }
    validates :line_key, format: { with: /\A[0-9a-f-]{36}(?::[0-9a-f-]{36})?\z/ }
    validates :version_number, :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
    validates :source_type, inclusion: { in: %w[checkout subscription_change] }
    validate :safe_snapshot
    validate :line_identity_matches_mode

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
