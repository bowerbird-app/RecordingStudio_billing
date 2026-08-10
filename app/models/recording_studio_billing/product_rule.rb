# frozen_string_literal: true

module RecordingStudioBilling
  class ProductRule < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    RULE_TYPES = %w[
      requires excludes available_with replaces upgrade_from downgrade_from same_family
    ].freeze
    CONDITION_KEYS = %w[country_code account_recording_id selected_product_recording_ids].freeze

    commercial_recordable label: "Product rule", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :product_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :target_product_recording, class_name: "RecordingStudio::Recording", inverse_of: false, optional: true
    commercial_reference :product_recording, type: "RecordingStudioBilling::Product"
    commercial_reference :target_product_recording, type: "RecordingStudioBilling::Product"

    validates :rule_type, inclusion: { in: RULE_TYPES }
    validate :conditions_are_supported
    validate :published_rule_is_immutable, on: :update

    private

    def published_rule_is_immutable
      return unless state_was == "published" && changed?

      errors.add(:base, "published product rules are immutable")
    end

    def conditions_are_supported
      unless conditions.is_a?(Hash) && (conditions.keys.map(&:to_s) - CONDITION_KEYS).empty?
        errors.add(:conditions, "contains unsupported conditions")
        return
      end

      errors.add(:conditions, "values must be scalar values or arrays") unless conditions.values.all? do |value|
        value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
      end
    end
  end
end
