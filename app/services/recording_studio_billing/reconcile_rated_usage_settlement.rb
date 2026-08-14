# frozen_string_literal: true

module RecordingStudioBilling
  class ReconcileRatedUsageSettlement
    def self.call(...) = new(...).call

    def initialize(rated_usage_settlement:, root_recording: nil, lease_duration: FinancialCommandClaim::DEFAULT_LEASE)
      @settlement_input = rated_usage_settlement
      @root_recording_input = root_recording
      @lease_duration = lease_duration
    end

    def call
      settlement = RatedUsageSettlement.find(settlement_id)
      command = settlement.financial_command
      if command.state == "requires_reconciliation" && command.provider_reference.present?
        ReconcileProviderCommand.call(command:)
        ProjectRatedUsageSettlement.call(rated_usage_settlement: settlement)
      elsif command.state == "requires_reconciliation"
        ExecuteRatedUsageSettlement.call(rated_usage_settlement: settlement, root_recording: root_recording_input,
                                         recovery: true, lease_duration:)
      else
        ProjectRatedUsageSettlement.call(rated_usage_settlement: settlement)
      end
    end

    private

    attr_reader :lease_duration, :root_recording_input, :settlement_input

    def settlement_id
      settlement_input.respond_to?(:id) ? settlement_input.id : settlement_input
    end
  end
end
