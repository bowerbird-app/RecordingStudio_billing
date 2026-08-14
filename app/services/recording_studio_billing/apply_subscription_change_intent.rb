# frozen_string_literal: true

module RecordingStudioBilling
  class ApplySubscriptionChangeIntent
    def self.call(...) = new(...).call

    def initialize(subscription_change_intent:, root_recording:)
      @intent_input = subscription_change_intent
      @root_recording_input = root_recording
    end

    def call
      terminal_outcome = nil
      result = SubscriptionChangeIntent.transaction do
        intent = SubscriptionChangeIntent.joins(:subscription).where(recording_studio_billing_subscriptions: {
                                                                       root_recording_id: RecordingStudio.root_recording_or_self(root_recording_input).id
                                                                     }).lock.find(intent_id)
        return intent if intent.state == "applied"

        record_provider_outcome!(intent)
        if %w[failed requires_review].include?(intent.state)
          terminal_outcome = intent.state
          next intent
        end

        raise ArgumentError, "subscription change is not ready" unless %w[pending_provider
                                                                          scheduled].include?(intent.state)
        raise ArgumentError, "subscription change is not due" if intent.effective_at&.future?

        unless intent.financial_command&.state == "succeeded"
          raise ArgumentError,
                "subscription change command has not completed"
        end

        intent.update!(state: "applied")
        case intent.change_kind
        when "cancellation"
          cancel!(intent)
        when "resumption"
          resume!(intent)
        else
          append_frozen_version!(intent)
        end
        intent
      end
      raise ArgumentError, "subscription change provider outcome is #{terminal_outcome}" if terminal_outcome

      result
    end

    private

    attr_reader :intent_input, :root_recording_input

    def intent_id = intent_input.respond_to?(:id) ? intent_input.id : intent_input

    def record_provider_outcome!(intent)
      command = intent.financial_command&.reload
      return unless command

      case command.state
      when "failed", "cancelled"
        intent.update!(state: "failed", outcome: intent.outcome.merge("provider_result" => command.normalized_result))
      when "uncertain", "requires_reconciliation"
        intent.update!(state: "requires_review",
                       outcome: intent.outcome.merge("provider_result" => command.normalized_result))
      end
    end

    def cancel!(intent)
      subscription = intent.subscription
      SubscriptionLifecycle.cancel(subscription:, root_recording: subscription.root_recording)
      subscription.items.where(state: "active").find_each do |item|
        effective_at = intent.effective_at || Time.current
        item.versions.where(effective_ends_at: nil).find_each do |version|
          version.update!(effective_ends_at: effective_at, superseded_at: effective_at)
        end
        item.update!(state: "cancelled")
      end
    end

    def resume!(intent)
      return if intent.subscription.state == "active"

      SubscriptionLifecycle.resume_from_change(subscription: intent.subscription,
                                               root_recording: intent.subscription.root_recording)
      snapshots = intent.frozen_terms.fetch("current_items", {})
      intent.subscription.items.where(state: "cancelled").lock.find_each do |item|
        snapshot = snapshots.fetch(item.line_key)
        append_frozen_version!(intent, manifest_digest: snapshot.fetch("manifest_digest"), frozen_key: "current_items",
                                       frozen_snapshot: snapshot, stable_item: item)
        item.update!(state: "active")
      end
    end

    def append_frozen_version!(intent, manifest_digest: intent.proposed_manifest_digest, frozen_key: "proposed",
                               frozen_snapshot: nil, stable_item: nil)
      frozen_snapshot ||= intent.frozen_terms.fetch(frozen_key)
      manifest = authoritative_manifest!(intent, manifest_digest:, frozen_snapshot:)
      terms = manifest.canonical_data
      option = terms.fetch("billing_option")
      terms.fetch("product")
      mode = mode_for_terms(terms)
      raise ArgumentError, "subscription change requires a recurring commercial item" unless SubscriptionItemVersion::MODES.include?(mode)

      product_id = manifest_recording_id(manifest, "RecordingStudioBilling::Product")
      option_id = manifest_recording_id(manifest, "RecordingStudioBilling::BillingOption")
      price_id = manifest_recording_id(manifest, "RecordingStudioBilling::Price")
      provider_id = manifest_recording_id(manifest, "RecordingStudioBilling::ProviderAccount")
      line_key = mode == "recurring_addon" ? "#{product_id}:#{option_id}" : product_id.to_s
      stable_item ||= intent.subscription.items.lock.find_or_create_by!(line_key:) do |record|
        record.root_recording = intent.root_recording
        record.account_recording = intent.account_recording
        record.state = "active"
      end
      provider_adapter_key = stable_item.versions.where(effective_ends_at: nil).order(version_number: :desc).pick(:provider_adapter_key)
      provider_adapter_key ||= intent.subscription.item_versions.order(version_number: :desc).pick(:provider_adapter_key)
      raise ArgumentError, "subscription change has no provider adapter authority" if provider_adapter_key.blank?

      now = Time.current
      stable_item.versions.where(effective_ends_at: nil).find_each do |version|
        version.update!(effective_ends_at: now, superseded_at: now)
      end
      version = stable_item.versions.create!(subscription: intent.subscription, root_recording: intent.root_recording,
                                             account_recording: intent.account_recording, source_type: "subscription_change", source_id: intent.id,
                                             source_snapshot: frozen_snapshot, line_key:, version_number: stable_item.versions.maximum(:version_number).to_i + 1,
                                             product_recording_id: product_id, billing_option_recording_id: option_id,
                                             price_recording_id: price_id, provider_account_recording_id: provider_id,
                                             provider_adapter_key:, mode:, currency_code: terms.dig("price", "currency_code"),
                                             amount_minor: terms.dig("price", "amount_minor"), quantity: terms.dig("price", "quantity"), interval: option["interval"],
                                             interval_count: option["interval_count"], manifest_digest: manifest.manifest_digest,
                                             commercial_snapshot: frozen_snapshot, effective_starts_at: now)
      ProjectEntitlements.call(root_recording: intent.root_recording, source: version)
      version
    end

    def manifest_recording_id(manifest, recordable_type)
      recording_id, = manifest.snapshot_references.find do |_id, snapshot|
        snapshot["recordable_type"] == recordable_type
      end
      raise ArgumentError, "subscription change manifest recording authority is invalid" unless recording_id

      recording_id
    end

    def mode_for_terms(terms)
      option = terms.fetch("billing_option")
      product = terms.fetch("product")
      return "recurring_addon" if product.fetch("kind") == "addon"
      return "free_plan" if terms.dig("price", "amount_minor").zero?
      return "trial_subscription" if option.fetch("trial_days").positive?
      return "monthly_subscription" if option.fetch("interval") == "month"
      return "annual_subscription" if option.fetch("interval") == "year"

      raise ArgumentError, "unsupported commercial lifecycle mode"
    end

    def authoritative_manifest!(_intent, manifest_digest:, frozen_snapshot:)
      manifest = CommercialManifest.lock.find_by(manifest_digest:)
      raise ArgumentError, "proposed manifest is not authoritative" unless manifest&.used_at?

      envelope = {
        "manifest_digest" => manifest.manifest_digest,
        "schema_version" => manifest.schema_version,
        "resolver_version" => manifest.resolver_version,
        "root_recording_id" => manifest.root_recording_id,
        "canonical_data" => manifest.canonical_data,
        "recording_snapshots" => manifest.recording_snapshots,
        "snapshot_references" => manifest.snapshot_references
      }
      raise ArgumentError, "subscription change manifest snapshot is invalid" unless frozen_snapshot == envelope

      manifest
    end
  end
end
