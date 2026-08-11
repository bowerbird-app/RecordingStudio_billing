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
      raise ArgumentError, "unsupported_checkout_composition" unless items.one?

      intent = nil
      created = false
      CheckoutIntent.transaction do
        root = canonical_root
        account = direct_account(root)
        fingerprint = request_fingerprint(root)
        existing = CheckoutIntent.lock.find_by(root_recording_id: root.id, local_idempotency_key:)
        return Result.new(status: existing.request_fingerprint == fingerprint ? :existing : :conflict, intent: existing) if existing

        intent = CheckoutIntent.create!(root_recording: root, account_recording: account.recording,
                                        local_idempotency_key:, request_fingerprint: fingerprint,
                                        state: "validated", advisory_country_code: normalized_country,
                                        advisory_currency_code: normalized_currency, presentation_preference: presentation)
        resolved_items(root, account).each do |item|
          intent.items.create!(item.attributes.except("id", "checkout_intent_id", "created_at", "updated_at"))
        end
        created = true
      end
      enqueue_command!(intent) if created
      Result.new(status: :created, intent: intent.reload)
    rescue ActiveRecord::RecordNotUnique
      retry
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
          intent.update!(state: final.outcome == :review ? "requires_review" : "requires_requote")
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
      raise ActiveRecord::RecordNotFound, "billing account not found" unless recording && recording.recordable.root_recording_id == root.id

      recording.recordable
    end

    def resolved_items(root, account)
      raise ArgumentError, "at least one commercial item is required" if items.empty?

      items.map { |input| resolve_item(root, account, input.to_h.stringify_keys).first }
    end

    def resolve_item(root, account, input, stage: :provisional_charge, previous: nil, account_country: @account_country,
                     provider_country: @provider_country, host_country: @host_country, presentation: @presentation)
      permitted = %w[billing_option_recording_id quantity]
      raise ArgumentError, "unsupported checkout input" unless (input.keys - permitted).empty?

      option = BillingOption.with_current_recording.find_by!(recording_studio_recordings: { id: input.fetch("billing_option_recording_id") }, state: "published")
      product = option.product_recording.recordable
      raise ActiveRecord::RecordNotFound, "commercial item not found" unless product.is_a?(Product)
      eligibility = ProductRuleEvaluator.new(product:, selected_products: [product]).evaluate
      raise ArgumentError, "commercial item is ineligible" unless eligibility.eligible

      resolution = market_resolution(product, stage:, previous:, account_country:, provider_country:, host_country:)
      market = resolution.market
      currency = resolution.currency_code
      price = CommercialPriceSelector.new(billing_option: option, market:, currency_code: currency).price!
      provider = product.provider_account_recording.recordable
      selected_presentation = resolve_presentation(option, presentation:)
      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(provider.adapter_key)
      capability = adapter.capabilities.evaluate(operations: "checkout", currencies: currency,
                                                 markets: resolution.country_code, collection_methods: option.collection_method,
                                                 checkout_modes: selected_presentation,
                                                 quantities: option.quantity_mode, composition: "single")
      raise ArgumentError, capability.reason unless capability.supported?

      manifest = CommercialManifestResolver.new(product:, billing_option: option, price:, market:, currency_code: currency,
                                                quantity: input.fetch("quantity", option.default_quantity), account_recording: account.recording,
                                                trusted_context: { country_code: resolution.country_code,
                                                                   market_recording_id: market.recording.id,
                                                                   currency_code: currency,
                                                                   quantity: input.fetch("quantity", option.default_quantity) }).resolve!
      commercial_manifest = manifest.slice(:canonical_data, :recording_snapshots, :snapshot_references).stringify_keys
      CheckoutIntentItem.new(product_recording_id: product.recording.id, billing_option_recording_id: option.recording.id,
                             price_recording_id: price.recording.id, provider_account_recording_id: provider.recording.id,
                             market_recording_id: market.recording.id, product_recordable_type: product.class.name,
                             product_recordable_id: product.id, billing_option_recordable_type: option.class.name,
                             billing_option_recordable_id: option.id, quantity: input.fetch("quantity", option.default_quantity),
                             currency_code: currency, collection_method: option.collection_method, presentation: selected_presentation,
                             commercial_manifest:, manifest_digest: manifest.fetch(:manifest_digest)).then { |item| [item, resolution] }
    end

    def frozen_terms_match?(frozen_item, resolved_item)
      %w[product_recording_id billing_option_recording_id price_recording_id provider_account_recording_id
         market_recording_id product_recordable_type product_recordable_id billing_option_recordable_type
         billing_option_recordable_id quantity currency_code collection_method presentation manifest_digest].all? do |attribute|
        frozen_item.public_send(attribute) == resolved_item.public_send(attribute)
      end
    end

    def resolve_final_item(item, root, account, previous:, account_country:, provider_country:, host_country:)
      resolve_item(
        root, account, { "billing_option_recording_id" => item.billing_option_recording_id, "quantity" => item.quantity },
        stage: :final_charge, previous:, account_country:, provider_country:, host_country:, presentation: item.presentation
      )
    end

    def market_resolution(product, stage: :provisional_charge, previous: nil, account_country: @account_country, provider_country: @provider_country, host_country: @host_country)
      provider_id = product.provider_account_recording_id
      markets = Market.with_current_recording.where(provider_account_recording_id: provider_id, state: "published").to_a
      MarketResolver.new(markets:).resolve(stage:, declaration_country: normalized_country, explicit_currency: normalized_currency,
                                           account_country:, provider_country:, host_country:, previous:)
    end

    def resolve_presentation(option, presentation: @presentation)
      selected = presentation.presence || (option.collection_method == "invoice" ? "invoice" : "redirect")
      raise ArgumentError, "unsupported_checkout_mode" unless CheckoutIntentItem::PRESENTATIONS.include?(selected)
      raise ArgumentError, "unsupported_checkout_mode" if selected == "payment_link"

      selected
    end

    def enqueue_command!(intent)
      CheckoutIntent.transaction do
        intent.lock!
        item = intent.items.first
        manifest = item.commercial_manifest
        published_manifest = persist_manifest!(item, manifest)
        published_manifest.mark_used!
        command = CreateFinancialCommand.call(root_recording: intent.root_recording, account_recording: intent.account_recording,
                                              command_type: "checkout", local_idempotency_key: "checkout:#{intent.id}",
                                              provider_account_recording: item.provider_account_recording_id,
                                              provider_adapter_key: item.provider_account_recording.recordable.adapter_key,
                                              commercial_manifest_digests: [item.manifest_digest],
                                              request: { checkout_intent_id: intent.id, presentation: item.presentation, quantity: item.quantity,
                                                         currency: item.currency_code, amount_minor: item.commercial_manifest.dig("canonical_data", "price", "amount_minor") }).command
        intent.update!(financial_command: command, state: "pending_provider")
        intent.attempts.create!(financial_command: command, attempt_number: 1, state: "pending")
      end
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
      CommercialManifestCanonicalizer.digest("root_recording_id" => root.id, "items" => items.map { |item| item.to_h.stringify_keys.slice("billing_option_recording_id", "quantity") }.sort_by { |item| item.fetch("billing_option_recording_id") }, "country_code" => normalized_country, "currency_code" => normalized_currency, "presentation" => presentation)
    end

    def normalized_country = country_code&.to_s&.upcase
    def normalized_currency = currency_code&.to_s&.upcase
  end
end