# frozen_string_literal: true

module RecordingStudioBilling
  class ExecuteRatedUsageSettlement
    SAFE_REPRESENTATIONS = %w[quantity meter invoice_line].freeze

    def self.call(...) = new(...).call

    def initialize(rated_usage_settlement:, root_recording: nil, recovery: false,
                   lease_duration: FinancialCommandClaim::DEFAULT_LEASE)
      @settlement_input = rated_usage_settlement
      @root_recording_input = root_recording
      @recovery = recovery
      @lease_duration = lease_duration
    end

    def call
      FinancialCommandExecutor.reject_ambient_transaction!
      settlement, command = eligible_settlement_and_command!
      execute(command)
      ProjectRatedUsageSettlement.call(rated_usage_settlement: settlement)
    rescue StandardError
      ProjectRatedUsageSettlement.call(rated_usage_settlement: settlement) if settlement
      raise
    end

    private

    attr_reader :lease_duration, :recovery, :root_recording_input, :settlement_input

    def eligible_settlement_and_command!
      RatedUsageSettlement.transaction do
        settlement = RatedUsageSettlement.lock.find(settlement_id)
        root = RecordingStudio.root_recording_or_self(root_recording_input || settlement.root_recording)
        raise ActiveRecord::RecordNotFound, "rated usage settlement not found" unless settlement.root_recording_id == root.id

        command = settlement.financial_command.lock!
        raise ArgumentError, "rated usage settlement command is invalid" unless command.command_type == "usage_settlement" &&
                                                                                command.root_recording_id == settlement.root_recording_id &&
                                                                                command.account_recording_id == settlement.account_recording_id &&
                                                                                command.provider_account_recording_id == settlement.provider_account_recording_id &&
                                                                                command.canonical_request.fetch("request") == settlement.canonical_request
        raise ArgumentError, "rated usage settlement is not submitted" unless settlement.usage_period.state == "submitted"

        expected_state = recovery ? "requires_reconciliation" : "pending"
        raise ArgumentError, "rated usage settlement is not executable" unless command.state == expected_state

        [settlement, command]
      end
    end

    def execute(command)
      requirements = { usage_settlement_representations: SAFE_REPRESENTATIONS }
      if recovery
        RecoverFinancialCommand.call(command:, provider_key: command.provider_adapter_key, lease_duration:,
                                     capability_requirements: requirements)
      else
        FinancialCommandExecutor.execute(command:, provider_key: command.provider_adapter_key,
                                         capability_requirements: requirements)
      end
    end

    def settlement_id
      settlement_input.respond_to?(:id) ? settlement_input.id : settlement_input
    end
  end
end
