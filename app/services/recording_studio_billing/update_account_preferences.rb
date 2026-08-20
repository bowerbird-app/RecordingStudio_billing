# frozen_string_literal: true

module RecordingStudioBilling
  class UpdateAccountPreferences
    ATTRIBUTES = %i[
      name contact_email billing_country_code billing_currency_code locale time_zone
      tax_location_country_code tax_location_region_code tax_location_postal_code
    ].freeze

    def self.call(...) = new(...).call

    def initialize(root_recording:, account_recording:, attributes:, actor: nil)
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @account_recording = account_recording
      @attributes = attributes.to_h.symbolize_keys.slice(*ATTRIBUTES)
      @actor = actor
    end

    def call
      recording = RecordingStudio::Recording.unscoped.find_by!(
        id: account_recording.id, root_recording_id: root_recording.id,
        parent_recording_id: root_recording.id, recordable_type: "RecordingStudioBilling::Account"
      )
      root_recording.revise(recording, actor: actor) do |revision|
        normalized_attributes.each { |attribute, value| revision.public_send("#{attribute}=", value) }
      end
      recording.reload.recordable
    end

    private

    attr_reader :account_recording, :actor, :attributes, :root_recording

    def normalized_attributes
      attributes.transform_values do |value|
        value.is_a?(String) ? value.strip.presence : value
      end.transform_keys(&:to_sym).tap do |values|
        %i[billing_country_code billing_currency_code tax_location_country_code].each do |key|
          values[key] = values[key]&.upcase
        end
      end
    end
  end
end
