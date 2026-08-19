# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionChangeIntent < RecordingStudioBilling::ApplicationRecord
    STATES = %w[draft validated awaiting_confirmation pending_provider scheduled applied failed requires_review
                cancelled expired].freeze
    KINDS = %w[plan interval addon quantity cancellation resumption].freeze

    # Revisions replace the subscription recordable row, so the change intent
    # points at the stable Recording instead of a snapshot id.
    belongs_to :subscription_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :financial_command, optional: true

    def subscription
      subscription_recording&.recordable
    end

    validates :local_idempotency_key, :request_fingerprint, presence: true
    validates :state, inclusion: { in: STATES }
    validates :change_kind, inclusion: { in: KINDS }
    validate :safe_change_set
    validate :valid_state_transition

    TRANSITIONS = {
      "draft" => %w[validated cancelled expired],
      "validated" => %w[awaiting_confirmation pending_provider scheduled cancelled failed requires_review expired],
      "awaiting_confirmation" => %w[pending_provider scheduled cancelled expired],
      "pending_provider" => %w[scheduled applied failed requires_review cancelled expired],
      "scheduled" => %w[pending_provider applied failed requires_review cancelled expired],
      "failed" => %w[pending_provider requires_review cancelled expired],
      "requires_review" => %w[pending_provider cancelled expired],
      "applied" => [], "cancelled" => [], "expired" => []
    }.freeze

    private

    def safe_change_set
      SafeFinancialPayload.validate!(change_set)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:change_set, e.message)
    end

    def valid_state_transition
      return unless persisted? && will_save_change_to_state?

      previous_state = state_change_to_be_saved.first
      return if TRANSITIONS.fetch(previous_state, []).include?(state)

      errors.add(:state, "transition is invalid")
    end
  end
end
