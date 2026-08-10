# frozen_string_literal: true

module RecordingStudioBilling
  module CommercialRecordable
    extend ActiveSupport::Concern

    STATES = %w[draft published retired].freeze
    KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/

    included do
      has_one :recording, as: :recordable, class_name: "RecordingStudio::Recording", dependent: :restrict_with_error

      validates :key, presence: true, format: { with: KEY_FORMAT }
      validates :key, uniqueness: true
      validates :state, inclusion: { in: STATES }
    end

    class_methods do
      def commercial_recordable(label:, allowed_parent_types:)
        recording_studio_recordable label: label, root: false, allowed_parent_types: allowed_parent_types
      end
    end
  end
end
