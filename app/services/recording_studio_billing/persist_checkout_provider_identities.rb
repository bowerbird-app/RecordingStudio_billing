# frozen_string_literal: true

module RecordingStudioBilling
  class PersistCheckoutProviderIdentities
    PREFIXES = {
      "subscription" => "sub_",
      "subscription_item" => "si_",
      "payment_intent" => "pi_",
      "invoice" => "in_"
    }.freeze

    def self.call(command:)
      new(command:).call
    end

    def self.persist(command:, remote_type:, remote_id:)
      new(command:).persist(remote_type, remote_id)
    end

    def initialize(command:)
      @command = command
    end

    def call
      return unless command.command_type == "checkout"

      result = command.normalized_result.to_h.stringify_keys
      persist("subscription", result["subscription"])
      persist("payment_intent", result["payment_intent"])
      persist("invoice", result["invoice"])
      persist("subscription_item", result["subscription_item"])
      Array(result["subscription_items"]).each { |id| persist("subscription_item", id) }
      self
    end

    def persist(remote_type, remote_id)
      prefix = PREFIXES[remote_type]
      return unless prefix

      id = opaque_id(remote_id, prefix)
      return unless id

      ProviderReference.find_or_create_by!(
        provider_adapter_key: command.provider_adapter_key,
        provider_account_recording_id: command.provider_account_recording_id,
        environment: command.provider_account_recording.recordable.environment,
        remote_type:,
        remote_id: id
      ) do |reference|
        reference.financial_command = command
        reference.reference = id
        reference.reference_type = remote_type
      end
    end

    private

    attr_reader :command

    def opaque_id(value, prefix)
      id = value.is_a?(Hash) ? value["id"] : value
      return unless id.is_a?(String) && id.start_with?(prefix) && id.bytesize.between?(1, 255)
      return unless id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/)

      id
    end
  end
end
