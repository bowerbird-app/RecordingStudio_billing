# frozen_string_literal: true

module RecordingStudioBilling
  class ProjectRatedUsageSettlement
    def self.call(...) = new(...).call

    def initialize(rated_usage_settlement:)
      @settlement_input = rated_usage_settlement
    end

    def call
      RatedUsageSettlement.transaction do
        settlement = RatedUsageSettlement.lock.find(settlement_id)
        command = settlement.financial_command.lock!
        verify_authority!(settlement, command)
        period = settlement.usage_period.lock!
        return settlement unless command.state == "succeeded"

        target_state = command.reconciliation_state == "reconciled" ? "reconciled" : "invoiced"
        period.update!(state: target_state) if period.state == "submitted"
        settlement
      end
    end

    private

    attr_reader :settlement_input

    def settlement_id
      settlement_input.respond_to?(:id) ? settlement_input.id : settlement_input
    end

    def verify_authority!(settlement, command)
      valid = command.command_type == "usage_settlement" &&
              command.root_recording_id == settlement.root_recording_id &&
              command.account_recording_id == settlement.account_recording_id &&
              command.provider_account_recording_id == settlement.provider_account_recording_id &&
              command.canonical_request.fetch("request") == settlement.canonical_request
      raise ArgumentError, "rated usage settlement command is invalid" unless valid
    end
  end
end
