# frozen_string_literal: true

module RecordingStudioBilling
  class ApplyPlanUpdate
    def self.call(...) = new(...).call

    def initialize(root_recording:, idempotency_key:, plan_update: nil, run: nil, confirmation: {})
      @plan_update_input = plan_update
      @run_input = run
      @root_recording_input = root_recording
      @confirmation = confirmation.to_h.stringify_keys
      @idempotency_key = idempotency_key.to_s
    end

    def call
      PlanUpdateRun.transaction do
        run_input = resolve_run_input
        update = run_input&.plan_update || PlanUpdate.with_current_recording.find(plan_update_id)
        unless update.recording.root_recording_id == RecordingStudio.root_recording_or_self(root_recording_input).id
          raise ActiveRecord::RecordNotFound,
                "plan update not found"
        end

        manifest = replacement_manifest!(update)
        run, created = run_input ? [run_input, false] : find_or_create_run!(update, manifest)
        return run if run.state == "applied"
        return run if created

        return run unless confirm_run!(run)
        return run if run.scheduled_at&.future?

        build_applications!(run, update, manifest)

        run.update!(state: "applying")
        apply_due_applications!(run)
        advance_run!(run)
        run
      end
    end

    private

    class ApplicationFailure < StandardError
      attr_reader :application, :state

      def initialize(application, state)
        @application = application
        @state = state
        super("plan update application #{state}")
      end
    end

    attr_reader :confirmation, :idempotency_key, :plan_update_input, :root_recording_input, :run_input

    def build_applications!(run, update, manifest)
      subscriptions_for(update).each do |subscription_recording|
        subscription = subscription_recording.recordable
        application = run.applications.find_or_initialize_by(plan_update: update, subscription_recording:)
        next if application.persisted? && application.state == "applied"

        intent = application.subscription_change_intent || CreateSubscriptionChangeIntent.for_plan_update(
          subscription: subscription_recording, root_recording: subscription.root_recording,
          local_idempotency_key: "plan-update:#{run.id}:#{subscription_recording.id}", plan_update: update,
          effective_at: run.scheduled_at, proposed_manifest: manifest
        ).intent
        application.assign_attributes(subscription_change_intent: intent, state: "pending")
        application.save!
      end
    end

    def plan_update_id = plan_update_input.respond_to?(:id) ? plan_update_input.id : plan_update_input

    def resolve_run_input
      return unless run_input

      identifier = run_input.respond_to?(:id) ? run_input.id : run_input
      run = PlanUpdateRun.lock.find(identifier)
      unless run.idempotency_key == idempotency_key
        raise ArgumentError,
              "plan update run idempotency key does not match"
      end

      run
    end

    def subscriptions_for(update)
      audience = update.replacement_configuration.fetch("audience", {})
      root_ids = Array(audience["root_recording_ids"])
      raise ArgumentError, "plan update audience must name customer roots" if root_ids.empty?

      scope = Subscription.with_current_recording
                          .where(root_recording_id: root_ids, state: %w[trialing active past_due paused])
      account_ids = Array(audience["account_recording_ids"])
      scope = scope.where(account_recording_id: account_ids) if account_ids.any?
      scope.map(&:recording)
    end

    def replacement_manifest!(update)
      digest = update.replacement_manifest_digest.presence || update.replacement_configuration["manifest_digest"]
      manifest = CommercialManifest.lock.find_by(manifest_digest: digest)
      raise ArgumentError, "plan update replacement manifest is not published" unless manifest&.used_at?

      unless manifest.root_recording_id == update.recording.root_recording_id
        raise ArgumentError,
              "plan update replacement manifest belongs to another provider root"
      end

      manifest
    end

    def find_or_create_run!(update, manifest)
      fingerprint = CommercialManifestCanonicalizer.digest(
        "plan_update_id" => update.id, "manifest_digest" => manifest.manifest_digest,
        "confirmation" => confirmation, "idempotency_key" => idempotency_key
      )
      existing = update.runs.lock.find_by(idempotency_key:)
      raise ArgumentError, "plan update idempotency conflict" if existing && existing.request_fingerprint != fingerprint
      return [existing, false] if existing

      run = update.runs.create!(idempotency_key:, request_fingerprint: fingerprint, confirmation: {}, preview: {
                                  "replacement_manifest_digest" => manifest.manifest_digest,
                                  "audience" => update.replacement_configuration.fetch("audience", {})
                                }, scheduled_at: update.replacement_configuration["effective_at"],
                                state: update.replacement_configuration["effective_at"].present? ? "scheduled" : "awaiting_confirmation")
      [run, true]
    end

    def confirm_run!(run)
      if run.confirmation.blank?
        return false if confirmation.blank?

        run.update!(confirmation:, state: run.scheduled_at ? "scheduled" : "applying")
      elsif confirmation.present? && run.confirmation != confirmation
        raise ArgumentError, "plan update confirmation does not match"
      end
      true
    end

    def apply_due_applications!(run)
      return if run.scheduled_at&.future?

      applications = run.applications.includes(subscription_change_intent: :financial_command).order(:id).to_a
      return if applications.empty?
      return if preflight_applications!(applications)

      PlanUpdateRun.transaction(requires_new: true) do
        applications.each do |application|
          intent = application.subscription_change_intent
          ApplySubscriptionChangeIntent.call(subscription_change_intent: intent,
                                             root_recording: intent.root_recording)
          application.update!(state: "applied")
        rescue ArgumentError
          raise ApplicationFailure.new(application, "requires_review")
        rescue ActiveRecord::ActiveRecordError
          raise ApplicationFailure.new(application, "failed")
        end
      end
    rescue ApplicationFailure => e
      e.application.update!(state: e.state)
    rescue ArgumentError
      run.applications.where(state: "pending").first&.update!(state: "requires_review")
    rescue ActiveRecord::ActiveRecordError
      run.applications.where(state: "pending").first&.update!(state: "failed")
    end

    def preflight_applications!(applications)
      blocking = false
      applications.each do |application|
        if application.state == "applied"
          blocking ||= applications.any? { |candidate| candidate.state != "applied" }
          next
        end

        command_state = application.subscription_change_intent.financial_command&.state
        case command_state
        when nil, "succeeded"
          next
        when "failed", "cancelled"
          application.update!(state: "failed")
          blocking = true
        else
          application.update!(state: "requires_review")
          blocking = true
        end
      end
      blocking
    end

    def advance_run!(run)
      states = run.applications.pluck(:state)
      return run.update!(state: "requires_review") if states.include?("requires_review")
      return run.update!(state: "failed") if states.include?("failed")
      return run.update!(state: "applied") if states.any? && states.all? { |state| state == "applied" }

      run.update!(state: "applying")
    end
  end
end
