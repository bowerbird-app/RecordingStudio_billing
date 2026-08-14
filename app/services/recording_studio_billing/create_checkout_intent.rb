# frozen_string_literal: true

module RecordingStudioBilling
  class CreateCheckoutIntent
    Result = Data.define(:status, :intent) do
      def created? = status == :created
      def existing? = status == :existing
      def conflict? = status == :conflict
    end

    def self.call(...) = new(...).call

    def initialize(root_recording:, local_idempotency_key:, items:, country_code: nil, currency_code: nil,
                   presentation: nil, account_country: nil, provider_country: nil, host_country: nil)
      @root_input = root_recording
      @local_idempotency_key = local_idempotency_key.to_s
      @items = Array(items)
      @country_code = country_code
      @currency_code = currency_code
      @presentation = presentation
      @account_country = account_country
      @provider_country = provider_country
      @host_country = host_country
    end

    def call
      intent = nil
      created = false
      root = canonical_root
      account = direct_account(root)
      fingerprint = request_fingerprint(root)
      CheckoutIntent.transaction do
        existing = CheckoutIntent.lock.find_by(root_recording_id: root.id, local_idempotency_key:)
        if existing
          return Result.new(status: existing.request_fingerprint == fingerprint ? :existing : :conflict,
                            intent: existing)
        end

        resolved = resolved_items(root, account)
        intent = CheckoutIntent.create!(root_recording: root, account_recording: account.recording,
                                        local_idempotency_key:, request_fingerprint: fingerprint,
                                        state: "validated", advisory_country_code: normalized_country,
                                        advisory_currency_code: normalized_currency, presentation_preference: presentation)
        validate_composition!(resolved)
        resolved.each do |item|
          intent.items.create!(item.attributes.except("id", "checkout_intent_id", "created_at", "updated_at"))
        end
        created = true
      end
      enqueue_command!(intent) if created
      Result.new(status: :created, intent: intent.reload)
    rescue ActiveRecord::RecordNotUnique
      existing = CheckoutIntent.find_by(root_recording_id: root.id, local_idempotency_key:)
      raise unless existing

      Result.new(status: existing.request_fingerprint == fingerprint ? :existing : :conflict, intent: existing)
    end

    def verify_final_market!(intent:, account_country: nil, provider_country: nil, host_country: nil)
      CheckoutIntent.transaction do
        intent = CheckoutIntent.for_root(intent.root_recording).lock.find_by(id: intent.id)
        raise ActiveRecord::RecordNotFound, "checkout intent not found" unless intent

        account = direct_account(intent.root_recording)
        intent.items.lock.each do |item|
          previous = MarketResolver::Resolution.new(item.market_recording.recordable, item.currency_code, nil,
                                                    :provisional_charge, nil, :resolved, nil)
          final_item, final = resolve_final_item(item, intent.root_recording, account, previous:, account_country:,
                                                                                       provider_country:, host_country:)
          next if final.outcome == :confirmed && frozen_terms_match?(item, final_item)

          invalidate_scheduled_command!(intent)
          intent.update!(state: final_verification_state(final))
          break
        rescue ArgumentError, ActiveRecord::RecordNotFound
          invalidate_scheduled_command!(intent)
          intent.update!(state: "requires_review")
          break
        end
        intent
      end
    end

    private

    attr_reader :account_country, :country_code, :currency_code, :host_country, :items, :local_idempotency_key,
                :presentation, :provider_country, :root_input

    def canonical_root
      root = RecordingStudio.root_recording_or_self(root_input)
      RecordingStudio.assert_root_recording!(root)
      RecordingStudio::Recording.unscoped.find(root.id)
    end

    def direct_account(root)
      recording = RecordingStudio::Recording.unscoped.find_by(root_recording_id: root.id, parent_recording_id: root.id,
                                                              recordable_type: "RecordingStudioBilling::Account")
      unless recording && recording.recordable.root_recording_id == root.id
        raise ActiveRecord::RecordNotFound,
              "billing account not found"
      end

      recording.recordable
    end

    def resolved_items(root, account)
      raise ArgumentError, "at least one commercial item is required" if items.empty?

      option_ids = items.map { |input| input.to_h.stringify_keys.fetch("billing_option_recording_id") }
      raise ArgumentError, "duplicate checkout option" unless option_ids.uniq.size == option_ids.size

      resolved = items.map { |input| resolve_item(root, account, input.to_h.stringify_keys).first }
      validate_product_rules!(resolved, account)
      resolved
    end

    def resolve_item(_root, account, input, stage: :provisional_charge, previous: nil, account_country: @account_country,
                     provider_country: @provider_country, host_country: @host_country, presentation: @presentation)
      permitted = %w[billing_option_recording_id quantity]
      raise ArgumentError, "unsupported checkout input" unless (input.keys - permitted).empty?

      option = BillingOption.with_current_recording.find_by!(
        recording_studio_recordings: { id: input.fetch("billing_option_recording_id") }, state: "published", checkout_policy: "allowed"
      )
      product = option.product_recording.recordable
      raise ActiveRecord::RecordNotFound, "commercial item not found" unless product.is_a?(Product)

      resolution = market_resolution(product, stage:, previous:, account_country:, provider_country:, host_country:)
      market = resolution.market
      currency = resolution.currency_code
      price = CommercialPriceSelector.new(billing_option: option, market:, currency_code: currency).price!
      provider = product.provider_account_recording.recordable
      selected_presentation = resolve_presentation(option, provider, price, presentation:)
      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(provider.adapter_key)
      capability = adapter.capabilities.evaluate(operations: "checkout", currencies: currency,
                                                 markets: resolution.country_code, collection_methods: option.collection_method,
                                                 checkout_modes: selected_presentation,
                                                 quantities: option.quantity_mode)
      raise ArgumentError, capability.reason unless capability.supported?

      manifest = CommercialManifestResolver.new(product:, billing_option: option, price:, market:, currency_code: currency,
                                                quantity: input.fetch("quantity", option.default_quantity), account_recording: account.recording,
                                                trusted_context: { country_code: resolution.country_code,
                                                                   market_recording_id: market.recording.id,
                                                                   currency_code: currency,
                                                                   quantity: input.fetch("quantity",
                                                                                         option.default_quantity) }).resolve!
      commercial_manifest = manifest.slice(:canonical_data, :recording_snapshots, :snapshot_references).stringify_keys
      CheckoutIntentItem.new(product_recording_id: product.recording.id, billing_option_recording_id: option.recording.id,
                             price_recording_id: price.recording.id, provider_account_recording_id: provider.recording.id,
                             market_recording_id: market.recording.id, product_recordable_type: product.class.name,
                             product_recordable_id: product.id, billing_option_recordable_type: option.class.name,
                             billing_option_recordable_id: option.id, quantity: input.fetch("quantity", option.default_quantity),
                             currency_code: currency, collection_method: option.collection_method, presentation: selected_presentation,
                             commercial_manifest:, manifest_digest: manifest.fetch(:manifest_digest)).then do |item|
        [
          item, resolution
        ]
      end
    end

    def frozen_terms_match?(frozen_item, resolved_item)
      %w[product_recording_id billing_option_recording_id price_recording_id provider_account_recording_id
         market_recording_id product_recordable_type product_recordable_id billing_option_recordable_type
         billing_option_recordable_id quantity currency_code collection_method presentation manifest_digest].all? do |attribute|
        frozen_item.public_send(attribute) == resolved_item.public_send(attribute)
      end
    end

    def final_verification_state(resolution)
      policy = resolution.outcome == :confirmed ? resolution.market.verification_policy : resolution.outcome
      %i[review reject].include?(policy.to_sym) ? "requires_review" : "requires_requote"
    end

    def resolve_final_item(item, root, account, previous:, account_country:, provider_country:, host_country:)
      resolve_item(
        root, account, { "billing_option_recording_id" => item.billing_option_recording_id, "quantity" => item.quantity },
        stage: :final_charge, previous:, account_country:, provider_country:, host_country:, presentation: item.presentation
      )
    end

    def market_resolution(product, stage: :provisional_charge, previous: nil, account_country: @account_country,
                          provider_country: @provider_country, host_country: @host_country)
      provider_id = product.provider_account_recording_id
      markets = Market.with_current_recording.where(provider_account_recording_id: provider_id, state: "published").to_a
      MarketResolver.new(markets:).resolve(stage:, declaration_country: normalized_country, explicit_currency: normalized_currency,
                                           account_country:, provider_country:, host_country:, previous:)
    end

    def resolve_presentation(option, provider, price, presentation: @presentation)
      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(provider.adapter_key)
      selected = presentation.presence || default_presentation(option, price, adapter)
      raise ArgumentError, "unsupported_checkout_mode" unless CheckoutIntentItem::PRESENTATIONS.include?(selected)

      selected
    end

    def default_presentation(option, price, adapter)
      return "invoice" if option.collection_method == "invoice"
      return "no_charge" if price.amount_minor.zero? && adapter.capabilities.evaluate(checkout_modes: "no_charge").supported?

      adapter.capabilities.evaluate(checkout_modes: "embedded").supported? ? "embedded" : "redirect"
    end

    def validate_composition!(resolved)
      raise ArgumentError, "at least one commercial item is required" if resolved.empty?

      dimensions = {
        provider_account_recording_id: "mixed_provider_account",
        currency_code: "mixed_currency",
        collection_method: "mixed_collection_method",
        presentation: "mixed_checkout_presentation",
        market_recording_id: "mixed_charge_market"
      }
      dimensions.each do |attribute, error|
        raise ArgumentError, error unless resolved.map { |item| item.public_send(attribute) }.uniq.one?
      end

      intervals = resolved.filter_map do |item|
        option = item.commercial_manifest.dig("canonical_data", "billing_option")
        next unless option.fetch("recurrence") == "recurring"

        [option["interval"], option["interval_count"]]
      end
      raise ArgumentError, "mixed_recurring_intervals" unless intervals.uniq.one? || intervals.empty?

      recurring_terms = resolved.filter_map do |item|
        option = item.commercial_manifest.dig("canonical_data", "billing_option")
        next unless option.fetch("recurrence") == "recurring"

        [option.fetch("payment_terms_days"), option.fetch("lifecycle_policy"), option.fetch("proration_policy")]
      end
      raise ArgumentError, "mixed_subscription_terms" unless recurring_terms.uniq.one? || recurring_terms.empty?

      item = resolved.first
      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(item.provider_account_recording.recordable.adapter_key)
      capability = adapter.capabilities.evaluate(
        operations: "checkout", currencies: item.currency_code,
        collection_methods: item.collection_method, checkout_modes: item.presentation,
        composition: resolved.one? ? "single" : "mixed"
      )
      raise ArgumentError, capability.reason unless capability.supported?
    end

    def validate_product_rules!(resolved, account)
      active_products = active_subscription_products(account)
      products = active_products + resolved.map(&:product_recording).map(&:recordable)
      products.each do |product|
        result = ProductRuleEvaluator.new(product:, selected_products: products,
                                          current_product: active_products.find { |active_product| active_product.kind == "plan" }).evaluate
        raise ArgumentError, "commercial item is ineligible: #{result.violations.join(',')}" unless result.eligible
      end
    end

    def active_subscription_products(account)
      Subscription.for_root(canonical_root).where(account_recording: account.recording, state: %w[trialing active]).flat_map do |subscription|
        subscription.item_versions.where(effective_ends_at: nil).filter_map do |version|
          RecordingStudio::Recording.unscoped.find_by(id: version.product_recording_id)&.recordable
        end
      end
    end

    def enqueue_command!(intent)
      CheckoutIntent.transaction do
        intent.lock!
        items = intent.items.lock.to_a
        items.each do |item|
          published_manifest = persist_manifest!(item, item.commercial_manifest)
          published_manifest.mark_used!
        end
        item = items.first
        command = CreateFinancialCommand.call(root_recording: intent.root_recording, account_recording: intent.account_recording,
                                              command_type: "checkout", local_idempotency_key: "checkout:#{intent.id}",
                                              provider_account_recording: item.provider_account_recording_id,
                                              provider_adapter_key: item.provider_account_recording.recordable.adapter_key,
                                              commercial_manifest_digests: items.map(&:manifest_digest),
                                              request: { checkout_intent_id: intent.id, presentation: item.presentation,
                                                         currency: item.currency_code, collection_method: item.collection_method,
                                                         tax: checkout_tax_policy(items),
                                                         checkout_items: items.to_h do |checkout_item|
                                                           [checkout_item.id, checkout_command_item(checkout_item)]
                                                         end }).command
        intent.update!(financial_command: command, state: "pending_provider")
        intent.attempts.create!(financial_command: command, attempt_number: 1, state: "pending")
      end
    end

    def checkout_command_item(item)
      billing_option = item.commercial_manifest.dig("canonical_data", "billing_option")
      {
        checkout_intent_item_id: item.id,
        quantity: item.quantity,
        manifest_digest: item.manifest_digest,
        amount_minor: item.commercial_manifest.dig("canonical_data", "price", "amount_minor"),
        recurrence: billing_option.fetch("recurrence"),
        interval: billing_option["interval"],
        interval_count: billing_option["interval_count"]
      }
    end

    def checkout_tax_policy(items)
      policies = items.map { |item| item.commercial_manifest.dig("canonical_data", "tax_policy").stringify_keys }
      raise ArgumentError, "mixed_checkout_tax_policy" unless policies.uniq.one?

      policy = policies.first
      return { "enabled" => false } unless policy.fetch("enabled", false) == true
      return { "enabled" => false } unless policy.fetch("calculator_key") == "stripe_tax"

      provider = items.first.provider_account_recording.recordable
      return { "enabled" => false } unless provider.adapter_key == "stripe"

      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(provider.adapter_key)
      return { "enabled" => false } unless adapter.capabilities.evaluate(tax_modes: "provider").supported?

      {
        "enabled" => true, "mode" => "provider_native", "calculator_key" => "stripe_tax",
        "behavior" => policy.fetch("presentation"), "semantic_categories" => policy.fetch("semantic_categories"),
        "location_requirements" => policy.fetch("location_requirements")
      }
    end

    def invalidate_scheduled_command!(intent)
      command = intent.financial_command
      return unless command

      command.lock!
      return unless command.state == "pending"

      intent.attempts.where(state: "pending", financial_command_id: command.id).lock.find_each do |attempt|
        attempt.update!(state: "cancelled", completed_at: Time.current, safe_result: { "status" => "cancelled" })
      end
      command.update!(state: "cancelled")
    end

    def persist_manifest!(item, manifest)
      attributes = {
        root_recording_id: item.product_recording.root_recording_id,
        schema_version: CommercialManifest::SCHEMA_VERSION,
        resolver_version: CommercialManifest::RESOLVER_VERSION,
        canonical_data: manifest.fetch("canonical_data"),
        recording_snapshots: manifest.fetch("recording_snapshots"),
        snapshot_references: manifest.fetch("snapshot_references"),
        manifest_digest: item.manifest_digest
      }
      existing = CommercialManifest.lock.find_by(manifest_digest: item.manifest_digest)
      return CommercialManifest.create!(attributes) unless existing
      return existing if attributes.all? { |key, value| existing.public_send(key) == value }

      raise ArgumentError, "commercial manifest digest does not match frozen checkout terms"
    end

    def request_fingerprint(root)
      CommercialManifestCanonicalizer.digest("root_recording_id" => root.id, "items" => items.map do |item|
        item.to_h.stringify_keys.slice("billing_option_recording_id", "quantity")
      end.sort_by { |item| item.fetch("billing_option_recording_id") }, "country_code" => normalized_country, "currency_code" => normalized_currency, "presentation" => presentation)
    end

    def normalized_country = country_code&.to_s&.upcase
    def normalized_currency = currency_code&.to_s&.upcase
  end
end
