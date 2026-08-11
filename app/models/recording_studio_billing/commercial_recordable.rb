# frozen_string_literal: true

module RecordingStudioBilling
  module CommercialRecordable
    extend ActiveSupport::Concern

    STATES = %w[draft published retired].freeze
    KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/

    included do
      class_attribute :commercial_references, default: {}
      has_one :recording, as: :recordable, class_name: "RecordingStudio::Recording", dependent: :restrict_with_error
      scope :with_current_recording, -> { joins(:recording) }

      validates :key, presence: true, format: { with: KEY_FORMAT }
      # Recording Studio revisions duplicate immutable recordables. Keys are
      # stable catalogue terms, not database identities; Recording IDs provide
      # the stable, namespace-isolated identity across revisions.
      validates :state, inclusion: { in: STATES }
      validate :commercial_semantic_recordings_are_valid
      validate :publication_managed_state_is_authorized
    end

    class_methods do
      def commercial_recordable(label:, allowed_parent_types:)
        recording_studio_recordable label: label, root: false, allowed_parent_types: allowed_parent_types
      end

      def commercial_reference(name, type:, same_root: true)
        self.commercial_references = commercial_references.merge(name.to_sym => {
                                                                   type: type.to_s, same_root: same_root
                                                                 }).freeze
      end
    end

    def validate_commercial_semantic_recordings!
      self.class.commercial_references.each do |name, specification|
        validate_commercial_reference(name, specification)
      end
    end

    private

    def commercial_semantic_recordings_are_valid
      validate_commercial_semantic_recordings!
    end

    def publication_managed_state_is_authorized
      return if is_a?(FeatureOverride)
      return unless state != "draft"
      return if RecordingStudioBilling.commercial_publication_in_progress?

      errors.add(:state, "may only change through an authorized commercial publication")
    end

    def validate_commercial_reference(name, specification)
      reference = public_send(name)
      unless reference.is_a?(RecordingStudio::Recording) &&
             reference.recordable_type == specification.fetch(:type)
        errors.add(name, "must reference #{specification.fetch(:type)}")
        return
      end
      return unless specification.fetch(:same_root) && recording
      return if reference.root_recording_id == recording.root_recording_id

      errors.add(name, "must belong to the same Recording Studio root")
    end
  end
end
