# frozen_string_literal: true

module RecordingStudioBilling
  class Subscription < RecordingStudioBilling::ApplicationRecord
    recording_studio_recordable label: "Subscription", root: false,
                                allowed_parent_types: "RecordingStudioBilling::Account"

    STATES = %w[trialing active past_due paused cancelled expired].freeze
    LIVE_STATES = %w[trialing active].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    has_one :recording, as: :recordable, class_name: "RecordingStudio::Recording", dependent: :restrict_with_error

    scope :with_current_recording, -> { joins(:recording) }

    validates :identifier, presence: true
    validates :state, inclusion: { in: STATES }
    validates :provider_reference, length: { maximum: 512 }, allow_nil: true
    validate :direct_account_ownership
    validate :execution_group_authority

    class << self
      # Historical snapshots stay in the table, so every read that means "the
      # subscription as it stands now" has to go through the current Recording.
      def for_root(root_recording)
        with_current_recording.where(root_recording_id: RecordingStudio.root_recording_or_self(root_recording).id)
      end

      # Accepts the stable Recording, a current Subscription snapshot, or the id
      # of one, and always answers with the stable Recording.
      def recording_for(value, root_recording: nil)
        return value if value.is_a?(RecordingStudio::Recording)

        subscription = value.is_a?(Subscription) ? value : nil
        # Superseded snapshots keep their row and their id, so callers holding an
        # older one still have to land on the live Recording.
        subscription ||= snapshots_for(root_recording).find(value.respond_to?(:id) ? value.id : value)
        subscription.current_recording || raise(ActiveRecord::RecordNotFound, "subscription not found")
      end

      def snapshots_for(root_recording)
        return all unless root_recording

        where(root_recording_id: RecordingStudio.root_recording_or_self(root_recording).id)
      end

      def execution_group_fingerprint(values)
        Digest::SHA256.hexdigest([
          values.fetch(:provider_account_recording_id), values.fetch(:currency_code), values.fetch(:collection_method),
          values.fetch(:market_recording_id), values.fetch(:billing_anchor), values.fetch(:payment_terms_days)
        ].join(":"))
      end
    end

    # A revision leaves this row behind untouched, so never trust `self` or a
    # cached association here: re-read whichever snapshot the Recording points
    # at now, following the identifier that revisions carry forward.
    def current
      self.class.with_current_recording.find_by(root_recording_id:, identifier:)
    end

    def current_recording
      current&.recording
    end

    def lines
      subscription_recording = current_recording
      return SubscriptionLine.none unless subscription_recording

      SubscriptionLine.with_current_recording.where(subscription_recording_id: subscription_recording.id)
    end

    def active_lines
      lines.where(state: "active")
    end

    def cancelled_lines
      lines.where(state: "cancelled")
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
