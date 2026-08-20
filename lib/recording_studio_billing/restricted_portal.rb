# frozen_string_literal: true

module RecordingStudioBilling
  # Provider billing portals may update payment methods, address, tax IDs, and
  # invoice history. Plan, price, quantity, promotion, cancel, and resume changes
  # stay on Billing Intents so frozen terms remain authoritative.
  module RestrictedPortal
    ALLOWED_FEATURES = V1Contract::PORTAL_FEATURES
    FORBIDDEN_FEATURES = V1Contract::PORTAL_FORBIDDEN_FEATURES

    def self.normalize(features)
      Array(features).map { |feature| feature.to_s.strip }.reject(&:blank?).uniq
    end

    def self.validate_features!(features)
      normalized = normalize(features.presence || ALLOWED_FEATURES)
      forbidden = normalized & FORBIDDEN_FEATURES
      raise ArgumentError, "portal cannot change plans: #{forbidden.join(', ')}" if forbidden.any?

      extra = normalized - ALLOWED_FEATURES
      raise ArgumentError, "unsupported portal features: #{extra.join(', ')}" if extra.any?

      normalized
    end

    def self.stripe_configuration_features
      {
        "customer_update" => { "enabled" => true, "allowed_updates" => %w[address tax_id] },
        "invoice_history" => { "enabled" => true },
        "payment_method_update" => { "enabled" => true },
        "subscription_cancel" => { "enabled" => false },
        "subscription_update" => { "enabled" => false }
      }
    end
  end
end
