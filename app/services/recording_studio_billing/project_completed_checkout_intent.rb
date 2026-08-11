# frozen_string_literal: true

module RecordingStudioBilling
  class ProjectCompletedCheckoutIntent
    Result = Data.define(:status, :subscription, :purchase) do
      def projected? = status == :projected
      def existing? = status == :existing
    end

    def self.call(...) = new(...).call

    def initialize(checkout_intent:, root_recording: nil)
      @checkout_intent_input = checkout_intent
      @root_recording_input = root_recording
    end

    def call
      CheckoutIntent.transaction do
        intent = resolve_intent.lock!
        verify_eligibility!(intent)
        item = intent.items.lock.sole
        return existing_result(item) if existing_projection(item)

        mode = commercial_mode(item)
        result = SubscriptionItemVersion::MODES.include?(mode) ? project_subscription!(intent, item, mode) : project_purchase!(intent, item, mode)
        intent.update!(state: "completed") unless intent.state == "completed"
        result
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    attr_reader :checkout_intent_input, :root_recording_input

    def resolve_intent
      identifier = checkout_intent_input.respond_to?(:id) ? checkout_intent_input.id : checkout_intent_input
      scope = CheckoutIntent
      scope = scope.for_root(root_recording_input) if root_recording_input
      scope.find(identifier)
    end

    def verify_eligibility!(intent)
      root = RecordingStudio.root_recording_or_self(root_recording_input || intent.root_recording)
      raise ActiveRecord::RecordNotFound, "checkout intent not found" unless intent.root_recording_id == root.id
      raise ArgumentError, "checkout intent is not eligible for lifecycle projection" unless %w[awaiting_confirmation completed].include?(intent.state)
      command = intent.financial_command
      unless command&.command_type == "checkout" && command.state == "succeeded" && command.root_recording_id == intent.root_recording_id && command.account_recording_id == intent.account_recording_id
        raise ArgumentError, "checkout intent has no completed authoritative command"
      end
      account = intent.account_recording
      unless account.recordable_type == "RecordingStudioBilling::Account" && account.root_recording_id == root.id && account.parent_recording_id == root.id && account.recordable.root_recording_id == root.id
        raise ArgumentError, "checkout intent account authority is invalid"
      end
      raise ArgumentError, "unsupported_checkout_composition" unless intent.items.one?
      intent.items.each { |item| verify_frozen_item!(intent, command, item) }
    end

    def verify_frozen_item!(intent, command, item)
      raise ArgumentError, "checkout command authority is invalid" unless command.canonical_request.dig("authority", "commercial_manifest_digests")&.include?(item.manifest_digest)
      raise ArgumentError, "checkout provider authority is invalid" unless item.provider_account_recording_id == command.provider_account_recording_id && item.provider_account_recording.recordable.adapter_key == command.provider_adapter_key
      manifest = CommercialManifest.lock.find_by!(manifest_digest: item.manifest_digest)
      envelope = { "schema_version" => manifest.schema_version, "resolver_version" => manifest.resolver_version, "root_recording_id" => manifest.root_recording_id, "canonical_data" => manifest.canonical_data, "recording_snapshots" => manifest.recording_snapshots, "snapshot_references" => manifest.snapshot_references }
      unless manifest.used_at? && CommercialManifestCanonicalizer.digest(envelope) == manifest.manifest_digest && manifest.manifest_digest == item.manifest_digest
        raise ArgumentError, "checkout commercial manifests are invalid"
      end
      SafeFinancialPayload.validate!(item.commercial_manifest)
    end

    def commercial_mode(item)
      terms = item.commercial_manifest.fetch("canonical_data")
      option = terms.fetch("billing_option")
      price = terms.fetch("price")
      product = terms.fetch("product")
      recurrence = option.fetch("recurrence")
      amount = price.fetch("amount_minor")
      return "one_off_credit_pack" if recurrence == "one_time" && product.fetch("kind") == "credit_pack"
      return "one_off_addon" if recurrence == "one_time" && product.fetch("kind") == "addon"
      return "free_plan" if recurrence == "recurring" && amount.zero?
      return "trial_subscription" if recurrence == "recurring" && option.fetch("trial_days").positive?
      return "recurring_addon" if recurrence == "recurring" && product.fetch("kind") == "addon"
      return "monthly_subscription" if recurrence == "recurring" && option.fetch("interval") == "month"
      return "annual_subscription" if recurrence == "recurring" && option.fetch("interval") == "year"

      raise ArgumentError, "unsupported commercial lifecycle mode"
    end

    def existing_projection(item)
      SubscriptionItemVersion.find_by(checkout_intent_item_id: item.id) || Purchase.find_by(checkout_intent_item_id: item.id)
    end

    def existing_result(item)
      version = SubscriptionItemVersion.find_by(checkout_intent_item_id: item.id)
      return Result.new(status: :existing, subscription: version.subscription, purchase: nil) if version

      Result.new(status: :existing, subscription: nil, purchase: Purchase.find_by!(checkout_intent_item_id: item.id))
    end

    def project_subscription!(intent, item, mode)
      subscription = Subscription.lock.find_or_create_by!(root_recording: intent.root_recording, account_recording: intent.account_recording) do |record|
        record.identifier = SecureRandom.uuid
        record.state = mode == "trial_subscription" ? "trialing" : "active"
      end
      line_key = subscription_line_key(item, mode)
      previous = subscription.item_versions.where(line_key:, effective_ends_at: nil).order(version_number: :desc).first
      now = Time.current
      previous&.update!(effective_ends_at: now, superseded_at: now)
      terms = item.commercial_manifest.fetch("canonical_data")
      option = terms.fetch("billing_option")
      price = terms.fetch("price")
      subscription.item_versions.create!(root_recording: intent.root_recording, account_recording: intent.account_recording, checkout_intent: intent, checkout_intent_item_id: item.id, line_key:, version_number: subscription.item_versions.where(line_key:).maximum(:version_number).to_i + 1, product_recording_id: item.product_recording_id, billing_option_recording_id: item.billing_option_recording_id, price_recording_id: item.price_recording_id, provider_account_recording_id: item.provider_account_recording_id, provider_adapter_key: item.provider_account_recording.recordable.adapter_key, mode:, currency_code: item.currency_code, amount_minor: price.fetch("amount_minor"), quantity: item.quantity, interval: option["interval"], interval_count: option["interval_count"], manifest_digest: item.manifest_digest, commercial_snapshot: item.commercial_manifest, effective_starts_at: now)
      Result.new(status: :projected, subscription:, purchase: nil)
    end

    def subscription_line_key(item, mode)
      return "#{item.product_recording_id}:#{item.billing_option_recording_id}" if mode == "recurring_addon"

      item.product_recording_id.to_s
    end

    def project_purchase!(intent, item, mode)
      terms = item.commercial_manifest.fetch("canonical_data")
      purchase = Purchase.create!(root_recording: intent.root_recording, account_recording: intent.account_recording, checkout_intent: intent, checkout_intent_item_id: item.id, product_recording_id: item.product_recording_id, billing_option_recording_id: item.billing_option_recording_id, price_recording_id: item.price_recording_id, provider_account_recording_id: item.provider_account_recording_id, provider_adapter_key: item.provider_account_recording.recordable.adapter_key, mode:, currency_code: item.currency_code, amount_minor: terms.dig("price", "amount_minor"), quantity: item.quantity, manifest_digest: item.manifest_digest, commercial_snapshot: item.commercial_manifest, completed_at: Time.current)
      effect_kind = mode == "one_off_credit_pack" ? "credit_pack" : "one_off_addon"
      purchase.effects.create!(root_recording: intent.root_recording, account_recording: intent.account_recording, effect_kind:, idempotency_key: "checkout-item:#{item.id}:#{effect_kind}", manifest_digest: item.manifest_digest, safe_metadata: { "product_recording_id" => item.product_recording_id, "quantity" => item.quantity }, effective_at: purchase.completed_at)
      Result.new(status: :projected, subscription: nil, purchase:)
    end
  end
end