# frozen_string_literal: true

module RecordingStudioBilling
  class ProductRule < ApplicationRecord
    include CommercialRecordable

    RULE_TYPES = %w[
      requires excludes available_with replaces upgrade_from downgrade_from same_family
    ].freeze

    commercial_recordable label: "Product rule", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :product_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :rule_type, inclusion: { in: RULE_TYPES }
    validate :published_rule_is_immutable, on: :update

    private

    def published_rule_is_immutable
      return unless state_was == "published" && changed?

      errors.add(:base, "published product rules are immutable")
    end
  end
end
