# frozen_string_literal: true

module RecordingStudioBilling
  class Market < ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Market", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :priority, :specificity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :ppa_policy, :rounding_policy, :tax_presentation_policy, :verification_policy,
              presence: true, format: { with: CommercialRecordable::KEY_FORMAT }
    validate :country_codes_are_iso_codes
    validate :allowed_currency_codes_are_iso_codes

    private

    def country_codes_are_iso_codes
      validate_code_set(:country_codes, /\A[A-Z]{2}\z/, "ISO 3166-1 alpha-2 country codes")
    end

    def allowed_currency_codes_are_iso_codes
      validate_code_set(:allowed_currency_codes, /\A[A-Z]{3}\z/, "ISO 4217 currency codes")
    end

    def validate_code_set(attribute, format, description)
      values = public_send(attribute)
      return if values.is_a?(Array) && values.all? { |value| value.is_a?(String) && value.match?(format) }

      errors.add(attribute, "must be an array of #{description}")
    end
  end
end
