# frozen_string_literal: true

module RecordingStudioBilling
  class Rate < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Rate", allowed_parent_types: "RecordingStudioBilling::RateCard"

    belongs_to :rate_card_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :usage_unit_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    commercial_reference :rate_card_recording, type: "RecordingStudioBilling::RateCard"
    commercial_reference :usage_unit_recording, type: "RecordingStudioBilling::UsageUnit"

    validates :conversion_numerator, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :conversion_denominator, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :conversion_decimal, numericality: { greater_than: 0 }, allow_nil: true
    validate :conversion_representation

    private

    def conversion_representation
      if incomplete_rational_conversion?
        return errors.add(:base,
                          "rational conversions require a numerator and denominator")
      end
      if rational_conversion? && conversion_decimal.present?
        return errors.add(:base,
                          "use either a rational or decimal conversion")
      end
      return if rational_conversion? || conversion_decimal.present?

      errors.add(:base, "requires a rational or decimal conversion")
    end

    def rational_conversion?
      conversion_numerator.present? && conversion_denominator.present?
    end

    def incomplete_rational_conversion?
      conversion_numerator.present? != conversion_denominator.present?
    end
  end
end
