# frozen_string_literal: true

module RecordingStudioBilling
  class Subscription < RecordingStudioBilling::ApplicationRecord
    STATES = %w[trialing active past_due paused cancelled expired].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    has_many :items, class_name: "RecordingStudioBilling::SubscriptionItem", dependent: :restrict_with_error
    has_many :item_versions, class_name: "RecordingStudioBilling::SubscriptionItemVersion",
                             dependent: :restrict_with_error

    validates :identifier, presence: true, uniqueness: true
    validates :state, inclusion: { in: STATES }
    validates :provider_reference, length: { maximum: 512 }, allow_nil: true
    validate :direct_account_ownership
    validate :execution_group_authority

    def self.for_root(root_recording)
      where(root_recording_id: RecordingStudio.root_recording_or_self(root_recording).id)
    end

    def self.execution_group_fingerprint(values)
      Digest::SHA256.hexdigest([
        values.fetch(:provider_account_recording_id), values.fetch(:currency_code), values.fetch(:collection_method),
        values.fetch(:market_recording_id), values.fetch(:billing_anchor), values.fetch(:payment_terms_days)
      ].join(":"))
    end

    private

    def direct_account_ownership
      account = account_recording
      valid = root_recording && account && account.recordable_type == "RecordingStudioBilling::Account" &&
              account.root_recording_id == root_recording.id && account.parent_recording_id == root_recording.id &&
              account.recordable.root_recording_id == root_recording.id
      errors.add(:account_recording, "must belong directly to the normalized root") unless valid
    end

    def execution_group_authority
      return unless provider_account_recording_id? || market_recording_id?

      provider = RecordingStudio::Recording.unscoped.find_by(id: provider_account_recording_id)
      market = RecordingStudio::Recording.unscoped.find_by(id: market_recording_id)
      valid = provider&.recordable_type == "RecordingStudioBilling::ProviderAccount" &&
              market&.recordable_type == "RecordingStudioBilling::Market" &&
              market.recordable.provider_account_recording_id == provider_account_recording_id
      errors.add(:base, "subscription execution group is invalid") unless valid
      return unless valid && provider_account_recording_id? && currency_code? && collection_method? && market_recording_id? && billing_anchor? && execution_group_fingerprint?

      values = {
        provider_account_recording_id:, currency_code:, collection_method:, market_recording_id:, billing_anchor:, payment_terms_days:
      }
      return if execution_group_fingerprint == self.class.execution_group_fingerprint(values)

      errors.add(:execution_group_fingerprint,
                 "must match the execution identity")
    end
  end
end
