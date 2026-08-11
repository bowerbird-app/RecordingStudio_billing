# frozen_string_literal: true

module RecordingStudioBilling
  class ExpireFinancialCommandClaim
    def self.call(command:, now: Time.current)
      FinancialCommand.transaction do
        command.lock!
        return false unless command.state == "processing" && command.lease_expires_at &&
                            command.lease_expires_at <= now

        attempt = command.attempts.find_by!(state: "processing", completed_at: nil)
        details = { "reason" => "worker_lease_expired" }
        attempt.update!(
          state: "uncertain", completed_at: now, uncertain_outcome: true,
          safe_error_details: details
        )
        command.update!(
          state: "requires_reconciliation", reconciliation_state: "pending",
          safe_error_details: details, claim_token: nil, claimed_at: nil, lease_expires_at: nil
        )
        true
      end
    end
  end
end