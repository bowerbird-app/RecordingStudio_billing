# frozen_string_literal: true

require "securerandom"

module RecordingStudioBilling
  class FinancialCommandClaim
    DEFAULT_LEASE = 5.minutes
    Claim = Data.define(:command, :attempt, :token)

    def self.call(...)
      new(...).call
    end

    def initialize(command:, lease_duration: DEFAULT_LEASE, recovery: false, now: Time.current)
      @command = command
      @lease_duration = lease_duration
      @recovery = recovery
      @now = now
    end

    def call
      raise ArgumentError, "lease duration must be positive" unless lease_duration.positive?

      FinancialCommand.transaction do
        command.lock!
        return if live_claim?

        eligible_state = recovery ? "requires_reconciliation" : "pending"
        return unless command.state == eligible_state
        return unless checkout_intent_executable?
        return if !recovery && command.attempts.exists?

        token = SecureRandom.uuid
        command.update!(
          state: "processing", claim_token: token, claimed_at: now,
          lease_expires_at: now + lease_duration,
          reconciliation_state: recovery ? "processing" : command.reconciliation_state
        )
        attempt = command.attempts.create!(
          attempt_number: command.attempts.maximum(:attempt_number).to_i + 1,
          state: "processing", provider_idempotency_key: command.provider_idempotency_key,
          started_at: now
        )
        Claim.new(command:, attempt:, token:)
      end
    end

    private

    attr_reader :command, :lease_duration, :now, :recovery

    def checkout_intent_executable?
      return true unless command.command_type == "checkout"

      intent_id = command.canonical_request.dig("request", "checkout_intent_id")
      return false if intent_id.blank?

      CheckoutIntent.where(id: intent_id, financial_command_id: command.id, state: "pending_provider").exists?
    end

    def live_claim?
      command.state == "processing" && command.lease_expires_at.present? && command.lease_expires_at > now
    end
  end
end