# frozen_string_literal: true

module RecordingStudioBilling
  class CreditLedgerEntry < RecordingStudioBilling::ApplicationRecord
    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :purchase_effect, class_name: "RecordingStudioBilling::PurchaseEffect"

    validates :credit_key, :product_recording_id, presence: true
    validates :amount, numericality: { only_integer: true, greater_than: 0 }
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
  end
end