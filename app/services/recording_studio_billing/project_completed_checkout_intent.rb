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
        results = intent.items.lock.order(:created_at, :id).map do |item|
          if existing_projection(item)
            ensure_entitlements_for_existing!(item)
            next existing_result(item)
          end

          mode = commercial_mode(item)
          if SubscriptionLine::MODES.include?(mode)
            project_subscription!(intent, item,
                                  mode)
          else
            project_purchase!(intent, item,
                              mode)
          end
        end
        intent.update!(state: "completed") unless intent.state == "completed"
        combine_results(results)
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
      raise ArgumentError, "checkout intent is not eligible for lifecycle projection" unless %w[awaiting_confirmation
                                                                                                completed].include?(intent.state)

      command = intent.financial_command
      raise ArgumentError, "checkout intent has no completed authoritative command" unless command&.command_type == "checkout" && command.state == "succeeded" && command.root_recording_id == intent.root_recording_id && command.account_recording_id == intent.account_recording_id

      account = intent.account_recording
      raise ArgumentError, "checkout intent account authority is invalid" unless account.recordable_type == "RecordingStudioBilling::Account" && account.root_recording_id == root.id && account.parent_recording_id == root.id && account.recordable.root_recording_id == root.id

      intent.items.each { |item| verify_frozen_item!(intent, command, item) }
    end

    def verify_frozen_item!(_intent, command, item)
      raise ArgumentError, "checkout command authority is invalid" unless command.canonical_request.dig("authority",
                                                                                                        "commercial_manifest_digests")&.include?(item.manifest_digest)

      unless item.provider_account_recording_id == command.provider_account_recording_id && item.provider_account_recording.recordable.adapter_key == command.provider_adapter_key
        raise ArgumentError,
              "checkout provider authority is invalid"
      end

      manifest = CommercialManifest.lock.find_by!(manifest_digest: item.manifest_digest)
      envelope = { "schema_version" => manifest.schema_version, "resolver_version" => manifest.resolver_version,
                   "root_recording_id" => manifest.root_recording_id, "canonical_data" => manifest.canonical_data, "recording_snapshots" => manifest.recording_snapshots, "snapshot_references" => manifest.snapshot_references }
      raise ArgumentError, "checkout commercial manifests are invalid" unless manifest.used_at? && CommercialManifestCanonicalizer.digest(envelope) == manifest.manifest_digest && manifest.manifest_digest == item.manifest_digest

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

    # Revisions replace the line snapshot, so the oldest snapshot carrying the
    # checkout item id is the durable proof that the item was already projected.
    def origin_line(item)
      SubscriptionLine.where(checkout_intent_item_id: item.id).order(:created_at).first
    end

    def existing_projection(item)
      origin_line(item) || origin_purchase(item)
    end

    # Same durability rule as subscription lines: the oldest snapshot for the
    # checkout item proves the item was already projected, even if its Recording
    # later stops pointing at that row.
    def origin_purchase(item)
      Purchase.where(checkout_intent_item_id: item.id).order(:created_at).first
    end

    def existing_purchase(item)
      origin = origin_purchase(item)
      return unless origin

      origin.current || origin
    end

    def current_line_for(item)
      origin = origin_line(item)
      return unless origin

      SubscriptionLine.with_current_recording.find_by(subscription_recording_id: origin.subscription_recording_id,
                                                      line_key: origin.line_key)
    end

    def existing_result(item)
      origin = origin_line(item)
      return Result.new(status: :existing, subscription: origin.subscription_recording.reload.recordable, purchase: nil) if origin

      Result.new(status: :existing, subscription: nil, purchase: existing_purchase(item))
    end

    def ensure_entitlements_for_existing!(item)
      line = current_line_for(item)
      return project_entitlements_for!(line) if line

      project_entitlements_for!(existing_purchase(item))
    end

    def project_entitlements_for!(source)
      ProjectEntitlements.call(root_recording: source.root_recording, source:)
    end

    def combine_results(results)
      return results.first if results.one?

      status = results.all?(&:existing?) ? :existing : :projected
      Result.new(
        status:,
        subscription: results.filter_map(&:subscription).first,
        purchase: results.filter_map(&:purchase).first
      )
    end

    def project_subscription!(intent, item, mode)
      subscription_recording = find_or_record_subscription!(intent, subscription_identity(item), mode)
      reactivate_cancelled_subscription!(subscription_recording, intent)
      line = record_line!(intent, item, mode, subscription_recording)
      project_entitlements_for!(line)
      Result.new(status: :projected, subscription: subscription_recording.reload.recordable, purchase: nil)
    end

    # Only one subscription per execution group may be current. The unique index
    # cannot survive revisions, so serialize on the account Recording instead.
    def find_or_record_subscription!(intent, identity, mode)
      account_recording = intent.account_recording
      RecordingStudio::Recording.lock_ids!([account_recording.id]).load
      existing = Subscription.for_root(intent.root_recording).find_by(
        account_recording_id: account_recording.id,
        execution_group_fingerprint: identity.fetch(:execution_group_fingerprint)
      )
      return existing.recording if existing

      intent.root_recording.record(Subscription, parent_recording: account_recording) do |subscription|
        subscription.root_recording = intent.root_recording
        subscription.account_recording = account_recording
        subscription.identifier = SecureRandom.uuid
        subscription.state = mode == "trial_subscription" ? "trialing" : "active"
        subscription.provider_account_recording_id = identity.fetch(:provider_account_recording_id)
        subscription.currency_code = identity.fetch(:currency_code)
        subscription.collection_method = identity.fetch(:collection_method)
        subscription.billing_anchor = identity.fetch(:billing_anchor)
        subscription.payment_terms_days = identity.fetch(:payment_terms_days)
        subscription.market_recording_id = identity.fetch(:market_recording_id)
        subscription.execution_group_fingerprint = identity.fetch(:execution_group_fingerprint)
      end
    end

    def record_line!(intent, item, mode, subscription_recording)
      line_key = subscription_line_key(item, mode)
      attributes = line_attributes(intent, item, mode, subscription_recording, line_key)
      existing = SubscriptionLine.with_current_recording.find_by(
        subscription_recording_id: subscription_recording.id, line_key: line_key
      )
      line_recording = if existing
                         intent.root_recording.revise(existing.recording) do |line|
                           line.assign_attributes(attributes)
                         end
                       else
                         intent.root_recording.record(SubscriptionLine, parent_recording: subscription_recording) do |line|
                           line.assign_attributes(attributes)
                         end
                       end
      subscription_recording.reload.log_event!(
        action: "subscription_line_purchased",
        metadata: { "line_key" => line_key, "mode" => mode },
        idempotency_key: "checkout-item:#{item.id}"
      )
      line_recording.reload.recordable
    end

    def line_attributes(intent, item, mode, subscription_recording, line_key)
      terms = item.commercial_manifest.fetch("canonical_data")
      option = terms.fetch("billing_option")
      price = terms.fetch("price")
      {
        root_recording: intent.root_recording, account_recording: intent.account_recording,
        subscription_recording: subscription_recording, checkout_intent: intent, checkout_intent_item_id: item.id,
        source_type: "checkout", source_id: item.id, source_snapshot: item.commercial_manifest,
        line_key: line_key, state: "active", product_recording_id: item.product_recording_id,
        billing_option_recording_id: item.billing_option_recording_id, price_recording_id: item.price_recording_id,
        provider_account_recording_id: item.provider_account_recording_id,
        provider_adapter_key: item.provider_account_recording.recordable.adapter_key, mode: mode,
        currency_code: item.currency_code, amount_minor: price.fetch("amount_minor"), quantity: item.quantity,
        interval: option["interval"], interval_count: option["interval_count"],
        manifest_digest: item.manifest_digest, commercial_snapshot: item.commercial_manifest
      }
    end

    def reactivate_cancelled_subscription!(subscription_recording, intent)
      return unless subscription_recording.reload.recordable.state == "cancelled"

      SubscriptionLifecycle.resume_from_change(subscription: subscription_recording,
                                               root_recording: intent.root_recording)
      subscription_recording.reload
    end

    def subscription_identity(item)
      option = item.commercial_manifest.dig("canonical_data", "billing_option")
      values = {
        provider_account_recording_id: item.provider_account_recording_id,
        currency_code: item.currency_code,
        collection_method: item.collection_method,
        billing_anchor: option.fetch("lifecycle_policy"),
        payment_terms_days: option.fetch("payment_terms_days"),
        market_recording_id: item.market_recording_id
      }
      values.merge(execution_group_fingerprint: Subscription.execution_group_fingerprint(values))
    end

    def subscription_line_key(item, mode)
      return "#{item.product_recording_id}:#{item.billing_option_recording_id}" if mode == "recurring_addon"

      item.product_recording_id.to_s
    end

    def project_purchase!(intent, item, mode)
      attributes = purchase_attributes(intent, item, mode)
      purchase_recording = intent.root_recording.record(Purchase, parent_recording: intent.account_recording) do |purchase|
        purchase.assign_attributes(attributes)
      end
      intent.account_recording.reload.log_event!(
        action: "purchase_completed",
        metadata: { "mode" => mode, "product_recording_id" => item.product_recording_id },
        idempotency_key: "checkout-item:#{item.id}:purchase"
      )
      purchase = purchase_recording.reload.recordable
      project_entitlements_for!(purchase)
      Result.new(status: :projected, subscription: nil, purchase:)
    end

    def purchase_attributes(intent, item, mode)
      terms = item.commercial_manifest.fetch("canonical_data")
      {
        root_recording: intent.root_recording, account_recording: intent.account_recording,
        checkout_intent: intent, checkout_intent_item_id: item.id,
        product_recording_id: item.product_recording_id,
        billing_option_recording_id: item.billing_option_recording_id,
        price_recording_id: item.price_recording_id,
        provider_account_recording_id: item.provider_account_recording_id,
        provider_adapter_key: item.provider_account_recording.recordable.adapter_key, mode: mode,
        currency_code: item.currency_code, amount_minor: terms.dig("price", "amount_minor"),
        quantity: item.quantity, manifest_digest: item.manifest_digest,
        commercial_snapshot: item.commercial_manifest, completed_at: Time.current
      }
    end
  end
end
