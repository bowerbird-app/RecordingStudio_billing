# frozen_string_literal: true

module RecordingStudioBilling
  class ProviderAccount < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    commercial_recordable label: "Provider account", allowed_parent_types: "RecordingStudioBilling::BillingAdmin"
    CONFIGURATION_KEYS = %w[merchant public_account_id display_name statement_descriptor].freeze

    belongs_to :billing_admin_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    commercial_reference :billing_admin_recording, type: "RecordingStudioBilling::BillingAdmin"

    validates :adapter_key, presence: true, format: { with: CommercialRecordable::KEY_FORMAT }
    validates :name, :environment, presence: true
    validate :safe_configuration
    validate :capabilities_are_safe
    validate :supported_codes

    private

    def safe_configuration
      unless configuration.is_a?(Hash)
        errors.add(:configuration, "must be an object")
        return
      end

      validate_configuration_secrecy
      validate_configuration_keys
      validate_configuration_values
    end

    def validate_configuration_secrecy
      errors.add(:configuration, "must not contain credentials or secrets") if sensitive_key?(configuration)
    end

    def validate_configuration_keys
      unknown = configuration.keys.map(&:to_s) - CONFIGURATION_KEYS
      errors.add(:configuration, "contains unsupported keys: #{unknown.sort.join(', ')}") if unknown.any?
    end

    def validate_configuration_values
      return if configuration.values.all? { |value| public_metadata_value?(value) }

      errors.add(:configuration, "values must be scalar public metadata")
    end

    def public_metadata_value?(value)
      value.is_a?(String) || value.is_a?(Integer) || value == true || value == false
    end

    def capabilities_are_safe
      values = capabilities
      unless values.is_a?(Array) && values.all? { |value| value.is_a?(String) && value.match?(CommercialRecordable::KEY_FORMAT) }
        errors.add(:capabilities, "must be an array of capability keys")
      end
    end

    def supported_codes
      validate_codes(:supported_markets, /\A[A-Z]{2}\z/, "ISO 3166-1 alpha-2 country codes")
      validate_codes(:supported_currencies, /\A[A-Z]{3}\z/, "ISO 4217 currency codes")
    end

    def validate_codes(attribute, format, description)
      values = public_send(attribute)
      return if values.is_a?(Array) && values.all? { |value| value.is_a?(String) && value.match?(format) }

      errors.add(attribute, "must be an array of #{description}")
    end

    def sensitive_key?(value)
      case value
      when Hash
        value.any? do |key, nested_value|
          key.to_s.match?(/credential|password|secret|token|api[_-]?key/i) || sensitive_key?(nested_value)
        end
      when Array
        value.any? { |nested_value| sensitive_key?(nested_value) }
      else
        false
      end
    end
  end
end
