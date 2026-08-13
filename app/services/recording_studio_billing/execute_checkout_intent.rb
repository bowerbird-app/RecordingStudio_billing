# frozen_string_literal: true

module RecordingStudioBilling
  class ExecuteCheckoutIntent
    def self.call(...) = new(...).call

    def initialize(checkout_intent:, root_recording: nil, recovery: false,
                   lease_duration: FinancialCommandClaim::DEFAULT_LEASE,
                   provider_country: nil, host_country: nil)
      @checkout_intent_input = checkout_intent
      @root_recording_input = root_recording
      @recovery = recovery
      @lease_duration = lease_duration
      @provider_country = provider_country
      @host_country = host_country
    end

    def call
      FinancialCommandExecutor.reject_ambient_transaction!
      intent, command = eligible_intent_and_command!
      intent = verify_final_market!(intent)
      return intent unless intent.state == "pending_provider"

      adapter_key = command.provider_adapter_key

      if recovery
        RecoverFinancialCommand.call(
          command:, provider_key: adapter_key, lease_duration:,
          after_claim: ->(claim) { project_claim!(intent.id, claim, recovery: true) }
        )
      else
        claim = FinancialCommandClaim.call(
          command:, lease_duration:,
          after_claim: ->(claimed) { project_claim!(intent.id, claimed, recovery: false) }
        )
        return intent.reload unless claim

        adapter = RecordingStudioBilling.configuration.provider_registry.fetch(adapter_key)
        FinancialCommandExecutor.new(command:, adapter:).execute(claim:)
      end
      project_result!(intent.id, command.id)
      intent.reload
    rescue StandardError
      project_result!(intent.id, command.id) if intent && command
      raise
    end

    private

    attr_reader :checkout_intent_input, :host_country, :lease_duration, :provider_country,
                :recovery, :root_recording_input

    def verify_final_market!(intent)
      CreateCheckoutIntent.new(root_recording: intent.root_recording, local_idempotency_key: "verification",
                               items: []).verify_final_market!(intent:, provider_country:,
                                                               host_country: trusted_host_country(intent))
    end

    def trusted_host_country(intent)
      return host_country if host_country

      context = RecordingStudioBilling.configuration.billing_location_context_resolver&.call(
        root_recording: intent.root_recording, account_recording: intent.account_recording
      )
      context.to_h[:host_country]
    rescue StandardError
      nil
    end

    def eligible_intent_and_command!
      CheckoutIntent.transaction do
        intent = resolve_intent.lock!
        root = RecordingStudio.root_recording_or_self(root_recording_input || intent.root_recording)
        raise ActiveRecord::RecordNotFound, "checkout intent not found" unless intent.root_recording_id == root.id
        raise ArgumentError, "checkout intent is not executable" unless intent.state == "pending_provider"

        command = intent.financial_command
        raise ArgumentError, "checkout intent has no pending financial command" unless command

        command.lock!
        expected_command_state = recovery ? "requires_reconciliation" : "pending"
        raise ArgumentError, "checkout financial command is not executable" unless command.command_type == "checkout" && command.state == expected_command_state

        verify_frozen_authority!(intent, command)
        verify_checkout_attempt!(intent, recovery:)
        [intent, command]
      end
    end

    def resolve_intent
      identifier = checkout_intent_input.respond_to?(:id) ? checkout_intent_input.id : checkout_intent_input
      scope = CheckoutIntent
      if root_recording_input
        root = RecordingStudio.root_recording_or_self(root_recording_input)
        scope = scope.for_root(root)
      end
      scope.find(identifier)
    end

    def verify_frozen_authority!(intent, command)
      authority = command.canonical_request.fetch("authority")
      digests = authority.fetch("commercial_manifest_digests")
      unless authority["root_recording_id"] == intent.root_recording_id
        raise ArgumentError,
              "checkout command authority is invalid"
      end
      unless authority["provider_adapter_key"] == command.provider_adapter_key
        raise ArgumentError,
              "checkout command authority is invalid"
      end

      items = intent.items.lock.to_a
      raise ArgumentError, "checkout intent has no items" if items.empty?

      unless items.map(&:manifest_digest).sort == digests.sort
        raise ArgumentError,
              "checkout command authority is invalid"
      end
      raise ArgumentError, "checkout provider authority is invalid" unless items.all? do |item|
        item.provider_account_recording_id == command.provider_account_recording_id &&
        item.provider_account_recording.recordable.adapter_key == command.provider_adapter_key
      end

      manifests = CommercialManifest.where(manifest_digest: digests).lock.to_a
      raise ArgumentError, "checkout commercial manifests are invalid" unless manifests.size == digests.size

      manifests.each do |manifest|
        envelope = {
          "schema_version" => manifest.schema_version, "resolver_version" => manifest.resolver_version,
          "root_recording_id" => manifest.root_recording_id, "canonical_data" => manifest.canonical_data,
          "recording_snapshots" => manifest.recording_snapshots, "snapshot_references" => manifest.snapshot_references
        }
        next if manifest.used_at? && manifest.schema_version == CommercialManifest::SCHEMA_VERSION &&
                manifest.resolver_version == CommercialManifest::RESOLVER_VERSION &&
                CommercialManifestCanonicalizer.digest(envelope) == manifest.manifest_digest

        raise ArgumentError, "checkout commercial manifests are invalid"
      end
    end

    def verify_checkout_attempt!(intent, recovery:)
      current = intent.attempts.order(:attempt_number).last
      if recovery
        raise ArgumentError, "checkout recovery attempt is not ready" unless current&.completed_at?
      else
        raise ArgumentError, "checkout attempt is not ready" unless current&.state == "pending" && current.financial_command_attempt_id.nil?
      end
    end

    def project_claim!(intent_id, claim, recovery:)
      if recovery
        attempt = CheckoutAttempt.create!(checkout_intent_id: intent_id, financial_command: claim.command,
                                          financial_command_attempt: claim.attempt,
                                          attempt_number: claim.attempt.attempt_number, state: "pending")
        attempt.update!(state: "processing")
      else
        attempt = CheckoutAttempt.where(checkout_intent_id: intent_id, state: "pending").order(:attempt_number).last!
        attempt.update!(state: "processing", financial_command_attempt: claim.attempt)
      end
    end

    def project_result!(intent_id, command_id)
      CheckoutIntent.transaction do
        intent = CheckoutIntent.lock.find(intent_id)
        command = FinancialCommand.lock.find(command_id)
        command_attempt = command.attempts.order(:attempt_number).last
        return unless command_attempt&.completed_at?

        attempt = intent.attempts.lock.find_by!(financial_command_attempt_id: command_attempt.id)
        return if attempt.completed_at?

        state, intent_state = checkout_outcome(command)
        attempt.update!(state:, completed_at: command_attempt.completed_at,
                        safe_result: command_attempt.normalized_result,
                        safe_error_details: command_attempt.safe_error_details)
        intent.update!(state: intent_state) unless intent.state == intent_state
      end
    end

    def checkout_outcome(command)
      status = command.normalized_result["status"]
      return %w[succeeded awaiting_confirmation] if %w[success duplicate].include?(status)
      return %w[unknown pending_provider] if command.state == "requires_reconciliation" || %w[pending
                                                                                              unknown].include?(status)
      return %w[failed requires_review] if %w[unsupported provider_unavailable requires_review].include?(status)

      %w[failed failed]
    end
  end
end
