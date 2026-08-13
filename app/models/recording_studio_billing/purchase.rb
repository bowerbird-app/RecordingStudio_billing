# frozen_string_literal: true

module RecordingStudioBilling
  class Purchase < RecordingStudioBilling::ApplicationRecord
    MODES = %w[one_off_addon one_off_credit_pack].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :checkout_intent
    has_many :effects, class_name: "RecordingStudioBilling::PurchaseEffect", dependent: :restrict_with_error

    validates :mode, inclusion: { in: MODES }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :amount_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency_code, format: { with: /\A[A-Z]{3}\z/ }
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
    validate :safe_snapshot

    private

    def safe_snapshot
      SafeFinancialPayload.validate!(commercial_snapshot)
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:commercial_snapshot, e.message)
    end
  end
end
