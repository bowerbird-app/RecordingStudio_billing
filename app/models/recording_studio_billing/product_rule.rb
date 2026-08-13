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
    validate :target_product_is_present
    validate :conditions_are_supported
    validate :published_rule_is_immutable, on: :update

    def self.valid_conditions?(conditions)
      conditions.is_a?(Hash) &&
        (conditions.keys.map(&:to_s) - CONDITION_KEYS).empty? &&
        conditions.all? { |key, value| valid_condition_value?(key.to_s, value) }
    end

    def self.valid_condition_value?(key, value)
      values = Array(value)
      return false if values.empty? || values.any? { |item| !item.is_a?(String) || item.empty? }

      key != "country_code" || values.all? { |country| country.match?(/\A[A-Z]{2}\z/) }
    end

    private

    def published_rule_is_immutable
      return unless state_was == "published" && changed?

      errors.add(:base, "published product rules are immutable")
    end

    def conditions_are_supported
      errors.add(:conditions, "are malformed") unless self.class.valid_conditions?(conditions)
    end

    def target_product_is_present
      target = target_product_recording&.recordable
      source_root_id = product_recording&.root_recording_id
      return if target.is_a?(Product) && source_root_id && target.recording.root_recording_id == source_root_id

      errors.add(:target_product_recording, "must reference a Product in the same catalogue root")
    end
  end
end
