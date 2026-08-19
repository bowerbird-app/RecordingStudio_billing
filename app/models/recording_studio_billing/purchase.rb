# frozen_string_literal: true

module RecordingStudioBilling
  class Purchase < RecordingStudioBilling::ApplicationRecord
    recording_studio_recordable label: "Purchase", root: false,
                                allowed_parent_types: "RecordingStudioBilling::Account"

    MODES = %w[one_off_addon one_off_credit_pack].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :checkout_intent
    has_one :recording, as: :recordable, class_name: "RecordingStudio::Recording", dependent: :restrict_with_error

    scope :with_current_recording, -> { joins(:recording) }

    validates :mode, inclusion: { in: MODES }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
    validate :safe_snapshot
    validate :direct_account_ownership

    class << self
      # A purchase is only "the purchase" while its Recording points at it, so
      # every customer-facing read joins the current Recording.
      def for_root(root_recording)
        with_current_recording.where(root_recording_id: RecordingStudio.root_recording_or_self(root_recording).id)
      end

      # Accepts the stable Recording, a Purchase snapshot, or the id of either,
      # and always answers with the stable Recording.
      def recording_for(value, root_recording: nil)
        recording = resolve_recording(value)
        raise ActiveRecord::RecordNotFound, "purchase not found" unless recording

        raise ActiveRecord::RecordNotFound, "purchase not found" if root_recording && recording.root_recording_id != RecordingStudio.root_recording_or_self(root_recording).id

        recording
      end

      private

      def resolve_recording(value)
        return value if value.is_a?(RecordingStudio::Recording)
        return value.current_recording if value.is_a?(Purchase)

        identifier = value.respond_to?(:id) ? value.id : value
        RecordingStudio::Recording.find_by(id: identifier, recordable_type: name) ||
          find_by(id: identifier)&.current_recording
      end
    end

    # Purchases are bought once and never revised. The unique index on
    # checkout_intent_item_id enforces that. `current` still walks through the
    # Recording join so admin and customer reads stay consistent with
    # Subscription (only rows the Recording currently points at).
    def current
      self.class.with_current_recording.find_by(root_recording_id:, checkout_intent_item_id:)
    end

    def current_recording
      current&.recording
    end

    # Customer URLs carry the Recording id, matching Subscription#to_param.
    def to_param
      recording&.id || current_recording&.id || id
    end

    private

    def safe_snapshot
      SafeFinancialPayload.validate!(commercial_snapshot)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:commercial_snapshot, e.message)
    end

    def direct_account_ownership
      account = account_recording
      valid = root_recording && account && account.recordable_type == "RecordingStudioBilling::Account" &&
              account.root_recording_id == root_recording.id && account.parent_recording_id == root_recording.id &&
              account.recordable.root_recording_id == root_recording.id
      errors.add(:account_recording, "must belong directly to the normalized root") unless valid
    end
  end
end
