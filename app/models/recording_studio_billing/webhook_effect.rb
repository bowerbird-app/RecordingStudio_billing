# frozen_string_literal: true

module RecordingStudioBilling
  class WebhookEffect < RecordingStudioBilling::ApplicationRecord
    belongs_to :financial_command, optional: true
    belongs_to :provider_reference

    validates :provider_account_recording_id, :environment, :inbound_event_id, :handler_name, :action_version,
              presence: true
  end
end
