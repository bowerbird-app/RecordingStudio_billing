# frozen_string_literal: true

module RecordingStudioBilling
  class ExecuteSubscriptionChangeIntent
    def self.call(...) = new(...).call

    def initialize(subscription_change_intent:, root_recording: nil,
                   lease_duration: FinancialCommandClaim::DEFAULT_LEASE)
      @intent_input = subscription_change_intent
      @root_recording_input = root_recording
      @lease_duration = lease_duration
    end

    def call
      FinancialCommandExecutor.reject_ambient_transaction!
      intent, command = eligible_intent_and_command!
      return intent if FinancialCommandExecutor.subscription_change_not_due?(command)

      adapter_key = command.provider_adapter_key
      claim = FinancialCommandClaim.call(command:, lease_duration:)
      return intent.reload unless claim

      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(adapter_key)
      FinancialCommandExecutor.new(command:, adapter:).execute(claim:)
      intent.reload
    end

    private

    attr_reader :intent_input, :lease_duration, :root_recording_input

    def eligible_intent_and_command!
      SubscriptionChangeIntent.transaction do
        intent = resolve_intent.lock!
        root = RecordingStudio.root_recording_or_self(root_recording_input || intent.root_recording)
        raise ActiveRecord::RecordNotFound, "subscription change intent not found" unless intent.root_recording_id == root.id
        raise ArgumentError, "subscription change is not executable" unless %w[pending_provider scheduled].include?(intent.state)

        command = intent.financial_command
        raise ArgumentError, "subscription change has no pending financial command" unless command

        command.lock!
        raise ArgumentError, "subscription change command is not executable" unless command.command_type == "subscription_change" && command.state == "pending"

        [intent, command]
      end
    end

    def resolve_intent
      identifier = intent_input.respond_to?(:id) ? intent_input.id : intent_input
      scope = SubscriptionChangeIntent
      if root_recording_input
        root = RecordingStudio.root_recording_or_self(root_recording_input)
        scope = scope.where(root_recording_id: root.id)
      end
      scope.find(identifier)
    end
  end
end
