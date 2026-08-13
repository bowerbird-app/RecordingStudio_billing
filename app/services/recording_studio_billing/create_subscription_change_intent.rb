# frozen_string_literal: true

module RecordingStudioBilling
  class CreateSubscriptionChangeIntent
    Result = Data.define(:status, :intent) do
      def created? = status == :created
      def existing? = status == :existing
      def conflict? = status == :conflict
    end

    def self.call(...) = new(...).call

    def self.for_plan_update(subscription:, root_recording:, local_idempotency_key:, plan_update:, effective_at:,
                             proposed_manifest:)
      new(subscription:, root_recording:, local_idempotency_key:, change_kind: "plan", change_set: {}, effective_at:,
          proposed_manifest:, source: :plan_update,
          trusted_context: { "plan_update_id" => plan_update.id, "allowance_policy" => plan_update.allowance_policy }).call
    end

    def initialize(subscription:, root_recording:, local_idempotency_key:, change_kind:, change_set: {}, effective_at: nil,
                   proposed_manifest: nil, source: :customer, trusted_context: {})
      @subscription_input = subscription
      @root_recording_input = root_recording
      @local_idempotency_key = local_idempotency_key.to_s
      @change_kind = change_kind.to_s
      @change_set = change_set.to_h.stringify_keys
      @effective_at = effective_at
      @proposed_manifest = proposed_manifest
      @source = source.to_s
      @trusted_context = trusted_context.to_h.stringify_keys
    end

    def call
      SubscriptionChangeIntent.transaction do
        subscription = Subscription.for_root(root_recording_input).lock.find(subscription_id)
        validate_request!(subscription)
        current = current_item_versions(subscription).first
        proposed = authoritative_manifest(proposed_manifest)
        validate_proposed_manifest!(proposed)
        validate_proposed_execution_compatibility!(subscription, proposed)
        fingerprint = CommercialManifestCanonicalizer.digest("kind" => change_kind, "change_set" => change_set, "source" => source,
                                                             "trusted_context" => trusted_context,
                                                             "current_manifest_digest" => current&.manifest_digest,
                                                             "proposed_manifest_digest" => proposed&.manifest_digest,
                                                             "effective_at" => effective_at&.iso8601)
        existing = SubscriptionChangeIntent.lock.find_by(root_recording: subscription.root_recording,
                                                         local_idempotency_key:)
        if existing
          return Result.new(status: existing.request_fingerprint == fingerprint ? :existing : :conflict,
                            intent: existing)
        end

        provider_decision = provider_decision(subscription)
        intent = SubscriptionChangeIntent.create!(subscription:, root_recording: subscription.root_recording,
                                                  account_recording: subscription.account_recording,
                                                  local_idempotency_key:, request_fingerprint: fingerprint,
                                                  change_kind:, change_set:, effective_at:, current_manifest_digest: current&.manifest_digest,
                                                  proposed_manifest_digest: proposed&.manifest_digest,
                                                  frozen_terms: freeze_terms(subscription, current, proposed), provider_decision:,
                                                  outcome: expected_outcome(current, proposed), timing: effective_at ? "next_period" : "immediate",
                                                  proration_policy: current&.commercial_snapshot&.dig("canonical_data", "billing_option", "proration_policy") || "none",
                                                  state: effective_at&.future? ? "scheduled" : "validated")
        command = create_command!(intent, subscription)
        if command
          intent.update!(financial_command: command,
                         state: intent.state == "scheduled" ? "scheduled" : "pending_provider")
        end
        Result.new(status: :created, intent:)
      end
    end

    private

    attr_reader :change_kind, :change_set, :effective_at, :local_idempotency_key, :proposed_manifest, :root_recording_input, :source,
                :subscription_input, :trusted_context

    def subscription_id = subscription_input.respond_to?(:id) ? subscription_input.id : subscription_input

    def create_command!(intent, subscription)
      version = current_item_versions(intent.subscription).first
      return unless version

      manifest_digests = intent.frozen_terms.fetch("current_items", {}).values.filter_map do |snapshot|
        snapshot["manifest_digest"]
      end
      manifest_digests << intent.proposed_manifest_digest if intent.proposed_manifest_digest
      manifest_digests.uniq!

      CreateFinancialCommand.call(
        root_recording: intent.root_recording, account_recording: intent.account_recording,
        command_type: "subscription_change", local_idempotency_key: "subscription-change:#{intent.id}",
        provider_account_recording: version.provider_account_recording_id, provider_adapter_key: version.provider_adapter_key,
        commercial_manifest_digests: manifest_digests,
        request: { subscription_change_intent_id: intent.id, change_kind:, change_set: change_set.merge(
          "provider_subscription_reference" => subscription.provider_reference
        ), effective_at: effective_at&.iso8601,
                   current_manifest_digest: intent.current_manifest_digest, proposed_manifest_digest: intent.proposed_manifest_digest,
                   frozen_terms: intent.frozen_terms, timing: intent.timing, proration_policy: intent.proration_policy }
      ).command
    end

    def validate_request!(subscription)
      raise ArgumentError, "unsupported subscription change" unless SubscriptionChangeIntent::KINDS.include?(change_kind)
      raise ArgumentError, "subscription change key is required" if local_idempotency_key.empty?

      if effective_at && !effective_at.respond_to?(:iso8601)
        raise ArgumentError,
              "subscription change effective time is invalid"
      end

      return validate_plan_update_request!(subscription) if source == "plan_update"
      raise ArgumentError, "subscription change source is invalid" unless source == "customer"

      permitted = if %w[cancellation resumption].include?(change_kind)
                    []
                  else
                    %w[billing_option_recording_id quantity]
                  end
      raise ArgumentError, "subscription change contains unsupported input" unless (change_set.keys - permitted).empty?

      if permitted.any? && change_set["billing_option_recording_id"].blank?
        raise ArgumentError,
              "subscription change requires a commercial selection"
      end
      return unless change_set.key?("quantity")

      quantity = Integer(change_set.fetch("quantity"), exception: false)
      raise ArgumentError, "subscription quantity is invalid" unless quantity&.positive?

      @change_set["quantity"] = quantity
      return if subscription.item_versions.where(effective_ends_at: nil).exists?

      raise ArgumentError,
            "subscription has no active terms"
    end

    def validate_plan_update_request!(subscription)
      raise ArgumentError, "plan update authority is invalid" unless change_kind == "plan" && change_set.empty?
      raise ArgumentError, "plan update trusted context is invalid" unless trusted_context.keys.sort == %w[
        allowance_policy plan_update_id
      ]
      raise ArgumentError, "plan update allowance policy is invalid" unless PlanUpdate::ALLOWANCE_POLICIES.include?(trusted_context["allowance_policy"])
      raise ArgumentError, "plan update identifier is invalid" if trusted_context["plan_update_id"].blank?

      return if subscription.item_versions.where(effective_ends_at: nil).exists?

      raise ArgumentError,
            "subscription has no active terms"
    end

    def provider_decision(subscription)
      version = current_item_versions(subscription).first
      raise ArgumentError, "subscription has no provider authority" unless version

      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(version.provider_adapter_key)
      capability = adapter.capabilities.evaluate(operations: "subscription_change",
                                                 subscription_change_kinds: change_kind)
      raise ArgumentError, capability.reason unless capability.supported?

      {
        "adapter_key" => version.provider_adapter_key,
        "provider_account_recording_id" => version.provider_account_recording_id,
        "operation" => "subscription_change",
        "change_kind" => change_kind,
        "supported" => true
      }
    end

    def validate_proposed_manifest!(proposed)
      return unless proposed

      expected_option_id = change_set["billing_option_recording_id"]
      option_id = manifest_recording_id(proposed, "RecordingStudioBilling::BillingOption")
      raise ArgumentError, "subscription proposal does not match the selected billing option" if expected_option_id && option_id.to_s != expected_option_id.to_s
      return unless change_set.key?("quantity")

      return if proposed.canonical_data.dig("price", "quantity").to_i == change_set.fetch("quantity").to_i

      raise ArgumentError, "subscription proposal does not match the selected quantity"
    end

    def manifest_recording_id(manifest, recordable_type)
      recording_id, = manifest.snapshot_references.find do |_id, snapshot|
        snapshot["recordable_type"] == recordable_type
      end
      raise ArgumentError, "subscription proposal recording authority is invalid" unless recording_id

      recording_id
    end

    def validate_proposed_execution_compatibility!(subscription, proposed)
      return unless proposed

      versions = current_item_versions(subscription)
      raise ArgumentError, "subscription has no active execution terms" if versions.empty?

      baseline = versions.first
      provider = RecordingStudio::Recording.unscoped.find_by(id: baseline.provider_account_recording_id)
      raise ArgumentError, "subscription provider authority is invalid" unless provider&.recordable_type == "RecordingStudioBilling::ProviderAccount"

      terms = proposed.canonical_data
      option = terms.fetch("billing_option")
      price = terms.fetch("price")
      usage = terms.fetch("usage_settlement")
      trusted = terms.fetch("trusted_context")
      unless usage.fetch("provider_account_recording_id") == provider.id &&
             proposed.root_recording_id == provider.root_recording_id
        raise ArgumentError,
              "subscription proposal provider is incompatible"
      end
      unless price.fetch("currency_code") == subscription.currency_code
        raise ArgumentError,
              "subscription proposal currency is incompatible"
      end
      unless option.fetch("collection_method") == subscription.collection_method
        raise ArgumentError,
              "subscription proposal collection method is incompatible"
      end
      unless option.fetch("payment_terms_days") == subscription.payment_terms_days
        raise ArgumentError,
              "subscription proposal payment terms are incompatible"
      end
      unless trusted.fetch("market_recording_id") == subscription.market_recording_id
        raise ArgumentError,
              "subscription proposal market is incompatible"
      end
      raise ArgumentError, "subscription proposal is not recurring" unless option.fetch("recurrence") == "recurring"

      validate_recurring_composition!(versions, option)
      validate_proposed_product_rules!(subscription, proposed)
      validate_proposed_provider_capability!(provider, subscription, price)
    end

    def validate_recurring_composition!(versions, option)
      return if %w[plan interval].include?(change_kind)

      existing = versions.map { |version| [version.interval, version.interval_count] }.uniq
      proposed_interval = [option.fetch("interval"), option.fetch("interval_count")]
      raise ArgumentError, "subscription proposal interval is incompatible" unless existing.include?(proposed_interval)
    end

    def validate_proposed_product_rules!(subscription, proposed)
      product_id = manifest_recording_id(proposed, "RecordingStudioBilling::Product")

      product = Product.with_current_recording.find_by!(recording_studio_recordings: { id: product_id })
      current_products = current_item_versions(subscription).filter_map do |version|
        recording = RecordingStudio::Recording.unscoped.find_by(id: version.product_recording_id)
        recording&.recordable if recording&.recordable_type == "RecordingStudioBilling::Product"
      end
      selected_products = if %w[plan interval].include?(change_kind)
                            current_products.reject { |current_product| current_product.kind == "plan" } + [product]
                          elsif change_kind == "addon"
                            current_products + [product]
                          else
                            current_products
                          end
      selected_products.each do |selected_product|
        result = ProductRuleEvaluator.new(product: selected_product, selected_products:).evaluate
        raise ArgumentError, "subscription proposal violates product rules" unless result.eligible
      end
    end

    def validate_proposed_provider_capability!(provider, subscription, price)
      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(provider.recordable.adapter_key)
      composition = current_item_versions(subscription).size > 1 ? "mixed" : "single"
      capability = adapter.capabilities.evaluate(operations: "subscription_change", subscription_change_kinds: change_kind,
                                                 currencies: price.fetch("currency_code"), composition:)
      raise ArgumentError, capability.reason unless capability.supported?
    end

    def expected_outcome(current, proposed)
      current_price = current&.commercial_snapshot&.dig("canonical_data", "price") || {}
      proposed_price = proposed&.canonical_data&.dig("price") || current_price
      {
        "financial_effect" => {
          "current_amount_minor" => current_price["amount_minor"],
          "proposed_amount_minor" => proposed_price["amount_minor"],
          "currency_code" => proposed_price["currency_code"] || current_price["currency_code"],
          "authority" => "provider_pending"
        },
        "tax_effect" => { "authority" => "provider_pending" }
      }
    end

    def authoritative_manifest(value)
      return unless value

      manifest = if value.is_a?(CommercialManifest)
                   value
                 else
                   CommercialManifest.find_by(manifest_digest: value.respond_to?(:manifest_digest) ? value.manifest_digest : value)
                 end
      raise ArgumentError, "proposed manifest is not published" unless manifest&.used_at?

      manifest
    end

    def freeze_terms(subscription, current, proposed)
      current_items = subscription_item_snapshots(subscription)
      {
        "current" => current && current_items.fetch(current.line_key),
        "current_items" => current_items,
        "proposed" => proposed && manifest_envelope(proposed),
        "requested_change" => change_set,
        "plan_update" => source == "plan_update" ? trusted_context : nil
      }
    end

    def subscription_item_snapshots(subscription)
      versions = current_item_versions(subscription).sort_by(&:line_key)
      manifests = CommercialManifest.lock.where(manifest_digest: versions.map(&:manifest_digest)).index_by(&:manifest_digest)
      versions.each_with_object({}) do |version, snapshots|
        manifest = manifests[version.manifest_digest]
        validate_current_manifest!(manifest, version, subscription)
        snapshots[version.line_key] = manifest_envelope(manifest)
      end
    end

    def current_item_versions(subscription)
      active_versions = subscription.item_versions.where(effective_ends_at: nil).order(:created_at).to_a
      return active_versions unless active_versions.empty? && change_kind == "resumption"

      subscription.items.where(state: "cancelled").includes(:versions).flat_map do |item|
        item.versions.order(version_number: :desc).first
      end.compact
    end

    def validate_current_manifest!(manifest, version, subscription)
      raise ArgumentError, "subscription current manifest is unavailable" unless manifest&.used_at?

      canonical_envelope = manifest_envelope(manifest).except("manifest_digest")
      unless CommercialManifestCanonicalizer.digest(canonical_envelope) == manifest.manifest_digest &&
             manifest.manifest_digest == version.manifest_digest
        raise ArgumentError, "subscription current manifest is invalid"
      end

      provider_recording = RecordingStudio::Recording.unscoped.find_by(id: version.provider_account_recording_id)
      raise ArgumentError, "subscription current provider authority is invalid" unless provider_recording&.recordable_type == "RecordingStudioBilling::ProviderAccount"

      provider_root_id = provider_recording.root_recording_id
      allowed_root_ids = [subscription.root_recording_id, provider_root_id].compact
      return if allowed_root_ids.include?(manifest.root_recording_id)

      raise ArgumentError, "subscription current manifest belongs to another root"
    end

    def manifest_envelope(manifest)
      {
        "manifest_digest" => manifest.manifest_digest,
        "schema_version" => manifest.schema_version,
        "resolver_version" => manifest.resolver_version,
        "root_recording_id" => manifest.root_recording_id,
        "canonical_data" => manifest.canonical_data,
        "recording_snapshots" => manifest.recording_snapshots,
        "snapshot_references" => manifest.snapshot_references
      }
    end
  end
end
