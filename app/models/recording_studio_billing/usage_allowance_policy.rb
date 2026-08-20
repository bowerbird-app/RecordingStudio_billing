# frozen_string_literal: true

module RecordingStudioBilling
  class UsageAllowancePolicy < RecordingStudioBilling::ApplicationRecord
    POLICY_KINDS = %w[hard_limit prepaid_only prepaid_then_block prepaid_then_overage automatic_overage unlimited
                      addon_required].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :usage_period

    scope :active_at, lambda { |time|
      where(revoked_at: nil).where("effective_at <= ? AND (expires_at IS NULL OR expires_at > ?)", time, time)
    }

    validates :usage_key, :effective_at, presence: true
    validates :policy_kind, inclusion: { in: POLICY_KINDS }
    validates :limit_quantity, :consumed_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :consumption_does_not_exceed_limit

    private

    def consumption_does_not_exceed_limit
      return unless limit_quantity && consumed_quantity && consumed_quantity > limit_quantity

      errors.add(:consumed_quantity, "cannot exceed the limit")
    end
  end
end
