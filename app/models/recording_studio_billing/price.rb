# frozen_string_literal: true

module RecordingStudioBilling
  class Price < RecordingStudioBilling::ApplicationRecord
    include CommercialRecordable

    PRICING_MODELS = %w[flat per_unit package].freeze

    commercial_recordable label: "Price", allowed_parent_types: "RecordingStudioBilling::BillingOption"

    belongs_to :billing_option_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :market_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    commercial_reference :billing_option_recording, type: "RecordingStudioBilling::BillingOption"
    commercial_reference :market_recording, type: "RecordingStudioBilling::Market"

    validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :currency_exponent, numericality: { only_integer: true, in: 0..3 }
    validates :pricing_model, inclusion: { in: PRICING_MODELS }
    validates :scope, presence: true
    validates :version, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
    validates :billing_option_recording_id, uniqueness: {
      scope: %i[scope market_recording_id currency_code],
      conditions: -> { with_current_recording.where(state: "published") }
    }, if: -> { state == "published" }
    validate :package_size_matches_pricing_model
    validate :published_price_is_immutable, on: :update

    private

    def package_size_matches_pricing_model
      if pricing_model == "package"
        errors.add(:package_size, "must be a positive integer for package prices") unless package_size.to_i.positive?
      elsif package_size.present?
        errors.add(:package_size, "must be blank unless pricing_model is package")
      end
    end

    def published_price_is_immutable
      return unless state_was == "published" && changed?

      errors.add(:base, "published prices are immutable; create a replacement version")
    end
  end
end
