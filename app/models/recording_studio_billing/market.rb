# frozen_string_literal: true

module RecordingStudioBilling
  class Market < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Market", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"

    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    commercial_reference :provider_account_recording, type: "RecordingStudioBilling::ProviderAccount"

    validates :priority, :specificity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :default_currency_code, format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
    validates :ppa_policy, :rounding_policy, :tax_presentation_policy, :verification_policy,
              presence: true, format: { with: CommercialRecordable::KEY_FORMAT }
    validate :country_codes_are_iso_codes
    validate :allowed_currency_codes_are_iso_codes
    validate :country_groups_are_iso_codes
    validate :default_currency_is_allowed

    private

    def country_codes_are_iso_codes
      validate_code_set(:country_codes, /\A[A-Z]{2}\z/, "ISO 3166-1 alpha-2 country codes")
    end

    def allowed_currency_codes_are_iso_codes
      validate_code_set(:allowed_currency_codes, /\A[A-Z]{3}\z/, "ISO 4217 currency codes")
    end

    def validate_code_set(attribute, format, description)
      values = public_send(attribute)
      return if values.is_a?(Array) && values.present? &&
                values.all? { |value| value.is_a?(String) && value.match?(format) }

      errors.add(attribute, "must be an array of #{description}")
    end

    def country_groups_are_iso_codes
      return if valid_country_groups?

      errors.add(:country_groups, "must map group keys to non-empty ISO country code arrays")
    end

    def valid_country_groups?
      country_groups.is_a?(Hash) &&
        country_groups.all? { |name, countries| valid_country_group?(name, countries) }
    end

    def valid_country_group?(name, countries)
      name.to_s.match?(CommercialRecordable::KEY_FORMAT) &&
        countries.is_a?(Array) && countries.present? &&
        countries.all? { |country| country.is_a?(String) && country.match?(/\A[A-Z]{2}\z/) }
    end

    def default_currency_is_allowed
      return if default_currency_code.blank? || Array(allowed_currency_codes).include?(default_currency_code)

      errors.add(:default_currency_code, "must be one of the allowed currencies")
    end
  end
end
