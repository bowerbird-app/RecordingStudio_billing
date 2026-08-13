# frozen_string_literal: true

module RecordingStudioBilling
  class CheckoutIntentItem < RecordingStudioBilling::ApplicationRecord
    PRESENTATIONS = %w[embedded redirect payment_link invoice no_charge].freeze

    belongs_to :checkout_intent, inverse_of: :items
    belongs_to :product_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :billing_option_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :price_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :market_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :presentation, inclusion: { in: PRESENTATIONS }
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
    validate :safe_manifest

    private

    def safe_manifest
      SafeFinancialPayload.validate!(commercial_manifest)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:commercial_manifest, e.message)
    end
  end
end
