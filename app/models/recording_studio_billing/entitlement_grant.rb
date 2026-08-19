# frozen_string_literal: true

module RecordingStudioBilling
  class EntitlementGrant < RecordingStudioBilling::ApplicationRecord
    SOURCE_TYPES = %w[RecordingStudioBilling::SubscriptionLine RecordingStudioBilling::Purchase].freeze

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    belongs_to :account_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :source_type, inclusion: { in: SOURCE_TYPES }
    validates :source_id, :feature_key, presence: true
    validates :feature_kind, inclusion: { in: Feature::TYPES }
    validates :merge_rule, inclusion: { in: FeatureDefinitionRegistry::MERGE_RULES }
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }
    validate :safe_value

    private

    def safe_value
      SafeFinancialPayload.validate!({ "value" => value })
    rescue SafeFinancialPayload::UnsafeValue => e
      errors.add(:value, e.message)
    end
  end
end
