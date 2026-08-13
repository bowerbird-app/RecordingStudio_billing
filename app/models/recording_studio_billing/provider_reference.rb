# frozen_string_literal: true

module RecordingStudioBilling
  class ProviderReference < RecordingStudioBilling::ApplicationRecord
    belongs_to :financial_command
    belongs_to :provider_account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :provider_adapter_key, :environment, :remote_type, :remote_id, presence: true
    validates :remote_type, :remote_id, length: { maximum: 255 }, format: { with: /\A[a-zA-Z0-9_.:-]+\z/ }
    validate :provider_account_matches_command

    private

    def provider_account_matches_command
      provider = provider_account_recording&.recordable
      unless provider.is_a?(ProviderAccount)
        errors.add(:provider_account_recording, "must contain a ProviderAccount")
        return
      end
      unless provider.adapter_key == provider_adapter_key
        errors.add(:provider_adapter_key,
                   "must match the provider account")
      end
      errors.add(:environment, "must match the provider account") unless provider.environment == environment
      unless financial_command&.provider_account_recording_id == provider_account_recording_id
        errors.add(:financial_command,
                   "must use the same provider account")
      end
      return if financial_command&.provider_adapter_key == provider_adapter_key

      errors.add(:financial_command,
                 "must use the same provider adapter")
    end
  end
end
