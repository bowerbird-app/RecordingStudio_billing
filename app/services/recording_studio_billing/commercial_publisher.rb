# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity, Lint/MissingCopEnableDirective

module RecordingStudioBilling
  # Produces a deliberately small publication.  A publication is selected by its
  # Price recording identities; it never means "publish every draft below root".
  class CommercialPublisher
    SUPPORTED_MANIFEST_SCHEMA = CommercialManifest::SCHEMA_VERSION
    SUPPORTED_RESOLVER_VERSION = CommercialManifest::RESOLVER_VERSION

    def self.publish!(...)
      new(...).publish!
    end

    def self.activate!(...)
      new(...).activate!
    end

    def self.replace_price!(prior_price:, replacement_price:, **)
      new(**, price_recording_ids: [replacement_price.recording.id],
              replacements: { replacement_price.recording.id => prior_price.recording.id }).publish!
    end

    def self.replace_overage_price!(prior_overage_price:, replacement_overage_price:, price_recording_id:, **)
      new(**, price_recording_ids: [price_recording_id],
              replacements: { replacement_overage_price.recording.id => prior_overage_price.recording.id }).publish!
    end

    def initialize(root_recording: nil, effective_at: Time.current, candidate: nil, price_recording_ids: nil,
                   replacements: {}, rule_context: {}, actor: nil)
      @root_recording = root_recording
      @effective_at = effective_at
      @candidate = candidate
      @price_recording_ids = Array(price_recording_ids).compact.map(&:to_s).uniq.sort
      @replacements = replacements.to_h.stringify_keys
      @rule_context = rule_context.to_h
      @actor = actor
    end

    def publish!
      CommercialPublicationCandidate.transaction do
        root = canonical_root!
        authorize!(:publish, root:)
        graph = closure_for(root)
        lock_graph!(graph)
        graph = closure_for(root) # rebuild after every referenced row is locked
        validate_graph!(root, graph)

        manifests = persist_manifests(root, graph)
        envelope = snapshot_envelope(root, graph, manifests)
        candidate = find_or_create_candidate!(root, manifests, envelope)
        activate_candidate!(candidate) if candidate.effective_at <= Time.current
        candidate
      end
    end

    def activate!
      CommercialPublicationCandidate.transaction do
        publication = CommercialPublicationCandidate.lock.find(candidate_or_id)
        authorize!(:activate, root: RecordingStudio::Recording.unscoped.find(publication.root_recording_id),
                              publication:)
        return publication if publication.activated?
        raise ArgumentError, "publication candidate is not effective yet" if publication.effective_at > Time.current

        verify_candidate!(publication)
        activate_candidate!(publication)
      end
    end

    private

    attr_reader :root_recording, :effective_at, :candidate, :price_recording_ids, :replacements, :rule_context, :actor

    def canonical_root!
      root = RecordingStudio.root_recording_or_self(root_recording)
      RecordingStudio.assert_root_recording!(root)
      RecordingStudio::Recording.unscoped.lock.find(root.id)
    end

    def authorize!(action, root:, publication: nil)
      authorizer = RecordingStudioBilling.configuration.commercial_authorizer
      raise ArgumentError, "commercial publication requires an authorizer" unless authorizer
      raise ArgumentError, "commercial publication requires an actor" if actor.nil?
      return if authorizer.call(action:, actor:, root_recording: root, candidate: publication)

      raise ArgumentError, "commercial publication is not authorized"
    end

    def selected_prices(root)
      scope = Price.with_current_recording.where(recording_studio_recordings: { root_recording_id: root.id })
      if price_recording_ids.any?
        return scope.where(recording_studio_recordings: { id: price_recording_ids }).order(:id).to_a
      end

      drafts = scope.where(state: "draft").order(:id).to_a
      unless drafts.one?
        raise ArgumentError,
              "a price_recording_ids selection is required when more than one draft price exists"
      end

      drafts
    end

    def closure_for(root)
      prices = selected_prices(root)
      raise ArgumentError, "no selected draft or published price exists" if prices.empty?

      options = records_for(BillingOption, prices.map(&:billing_option_recording_id))
      markets = records_for(Market, prices.map(&:market_recording_id))
      products = records_for(Product, options.map(&:product_recording_id))
      features = Feature.with_current_recording.where(
        product_recording_id: products.map { |item| item.recording.id }
      ).where.not(state: "retired").order(:id).to_a
      rules = ProductRule.with_current_recording.where(
        product_recording_id: products.map { |item| item.recording.id }
      ).where.not(state: "retired").order(:id).to_a
      target_products = records_for(Product, rules.filter_map(&:target_product_recording_id))
      providers = records_for(
        ProviderAccount,
        (products + target_products + markets).map(&:provider_account_recording_id)
      )
      plan_updates = PlanUpdate.with_current_recording.where(
        billing_option_recording_id: options.map { |item| item.recording.id }
      ).where.not(state: "retired").order(:id).to_a
      overages = prices.flat_map do |price|
        OveragePrice.with_current_recording.where(
          billing_option_recording_id: price.billing_option_recording_id,
          market_recording_id: price.market_recording_id,
          currency_code: price.currency_code,
          scope: price.scope
        ).where.not(state: "retired").order(:id).to_a
      end
      overages.reject! { |overage| replacements.value?(overage.recording.id) }
      usage_units = records_for(UsageUnit, overages.map(&:usage_unit_recording_id))
      usage_unit_ids = usage_units.map { |item| item.recording.id }
      meters = Meter.with_current_recording.where(usage_unit_recording_id: usage_unit_ids)
                    .where.not(state: "retired").order(:id).to_a
      rates = Rate.with_current_recording.where(usage_unit_recording_id: usage_unit_ids)
                  .where.not(state: "retired").order(:id).to_a
      rate_cards = records_for(RateCard, rates.map(&:rate_card_recording_id))
      cost_rates = CostRate.with_current_recording.where(usage_unit_recording_id: usage_unit_ids)
                           .where.not(state: "retired").order(:id).to_a
      cost_cards = records_for(CostCard, cost_rates.map(&:cost_card_recording_id))
      replacements_records = replacement_records

      (prices + options + markets + products + providers + features + rules + target_products + plan_updates +
        overages + usage_units + meters + rate_cards + rates + cost_cards + cost_rates +
        replacements_records).uniq
    end

    def replacement_records
      ids = replacements.values
      return [] if ids.empty?

      RecordingStudio::Recording.unscoped.where(id: ids).order(:id).map do |recording|
        record = recording.recordable
        unless record.is_a?(Price) || record.is_a?(OveragePrice)
          raise ArgumentError,
                "replacement reference must be a Price or OveragePrice"
        end

        record
      end
    end

    def records_for(klass, recording_ids)
      ids = Array(recording_ids).compact.uniq
      return [] if ids.empty?

      records = klass.with_current_recording.where(recording_studio_recordings: { id: ids }).order(:id).to_a
      return records if records.size == ids.size

      raise ArgumentError, "missing #{klass.name.demodulize.underscore.tr('_', ' ')} reference"
    end

    def lock_graph!(graph)
      recording_ids = graph.map { |record| record.recording.id }.sort
      RecordingStudio::Recording.unscoped.where(id: recording_ids).order(:id).lock.load
      graph.group_by(&:class).each { |klass, records| klass.where(id: records.map(&:id)).order(:id).lock.load }
    end

    def validate_graph!(root, graph)
      records = graph.index_by { |record| record.recording.id }
      prices = selected_prices(root)
      validate_selected_price_identities!(prices)
      graph.each { |record| validate_record!(root, record, records) }
      prices.each { |price| validate_price!(price, records) }
      overages = graph.grep(OveragePrice).reject { |overage| replacements.value?(overage.recording.id) }
      validate_overages!(overages, records)
      validate_rules!(graph.grep(ProductRule), records, prices)
      validate_replacements!(records)
    end

    def validate_record!(root, record, records)
      recording = record.recording
      unless recording.root_recording_id == root.id
        raise ArgumentError,
              "commercial record is outside the selected root"
      end
      if recording.attributes["trashed_at"].present?
        raise ArgumentError,
              "trashed commercial records cannot be published"
      end
      raise ArgumentError, "retired commercial records cannot be published" if record.state == "retired"

      allowed = Array(RecordingStudio.allowed_parent_types_for(record.class))
      parent_type = recording.parent_recording&.recordable_type
      raise ArgumentError, "#{record.class.name} has an invalid recording parent" unless allowed.include?(parent_type)

      validate_provider!(record, records) if record.is_a?(ProviderAccount)
      validate_market!(record, records) if record.is_a?(Market)
      validate_feature!(record) if record.is_a?(Feature)
      validate_rate!(record, records) if record.is_a?(Rate)
      validate_cost_rate!(record, records) if record.is_a?(CostRate)
      record.validate_commercial_semantic_recordings! if record.respond_to?(:validate_commercial_semantic_recordings!)
      raise ArgumentError, "invalid #{record.class.name}" unless record.valid?
    end

    def validate_provider!(provider, _records)
      raise ArgumentError, "provider account is inactive" unless provider.active?
      return if provider.capabilities.blank? || provider.capabilities.intersect?(%w[catalogue commercial_catalogue])

      raise ArgumentError, "provider lacks commercial catalogue capability"
    end

    def validate_market!(market, records)
      provider = records.fetch(market.provider_account_recording_id)
      raise ArgumentError, "market provider is missing" unless provider.is_a?(ProviderAccount)
      unless Array(market.country_codes).all? do |code|
        provider.supported_markets.blank? || provider.supported_markets.include?(code)
      end
        raise ArgumentError, "market country is unsupported by provider"
      end
      unless Array(market.allowed_currency_codes).all? do |code|
        provider.supported_currencies.blank? || provider.supported_currencies.include?(code)
      end
        raise ArgumentError, "market currency is unsupported by provider"
      end
    end

    def validate_feature!(feature)
      definition = FeatureDefinitionRegistry.fetch!(feature.key)
      return if definition.fetch("type") == feature.kind

      raise ArgumentError, "feature kind does not match its registered definition"
    end

    def validate_rate!(rate, records)
      card = records[rate.rate_card_recording_id]
      usage_unit = records[rate.usage_unit_recording_id]
      unless card.is_a?(RateCard) && usage_unit.is_a?(UsageUnit)
        raise ArgumentError,
              "rate has incomplete references"
      end
      return if card.provider_account_recording_id == usage_unit.provider_account_recording_id

      raise ArgumentError, "rate card and usage unit use different providers"
    end

    def validate_cost_rate!(rate, records)
      card = records[rate.cost_card_recording_id]
      usage_unit = records[rate.usage_unit_recording_id]
      unless card.is_a?(CostCard) && usage_unit.is_a?(UsageUnit)
        raise ArgumentError,
              "cost rate has incomplete references"
      end
      return if card.provider_account_recording_id == usage_unit.provider_account_recording_id

      raise ArgumentError, "cost card and usage unit use different providers"
    end

    def validate_selected_price_identities!(prices)
      duplicates = prices.group_by { |price| price_identity(price) }
      raise ArgumentError, "ambiguous selected price identity" if duplicates.values.any? { |items| items.size > 1 }

      prices.each do |price|
        validate_current_version!(price)
        published = current_identity_scope(price).where(state: "published")
                                                 .where.not(recording_studio_recordings: { id: price.recording.id })
                                                 .to_a
        next if published.empty?

        prior_id = replacements[price.recording.id]
        unless published.one? && prior_id == published.first.recording.id
          raise ArgumentError,
                "a published price identity requires an explicit replacement"
        end
      end
    end

    def validate_price!(price, records)
      option = records[price.billing_option_recording_id]
      market = records[price.market_recording_id]
      unless option.is_a?(BillingOption) && market.is_a?(Market)
        raise ArgumentError,
              "price has incomplete billing option or market reference"
      end

      product = records[option.product_recording_id]
      unless product&.provider_account_recording_id == market.provider_account_recording_id
        raise ArgumentError,
              "price graph crosses provider accounts"
      end
      unless market.allowed_currency_codes.include?(price.currency_code)
        raise ArgumentError,
              "price currency is not permitted by market"
      end
      return if price.pricing_model == option.pricing_model

      raise ArgumentError,
            "price pricing model does not match billing option"
    end

    def validate_overages!(overages, records)
      duplicates = overages.group_by do |overage|
        [overage.billing_option_recording_id, overage.scope, overage.market_recording_id,
         overage.usage_unit_recording_id, overage.currency_code]
      end
      raise ArgumentError, "ambiguous overage price identity" if duplicates.values.any? { |items| items.size > 1 }

      overages.each do |overage|
        validate_current_version!(overage)
        option = records[overage.billing_option_recording_id]
        market = records[overage.market_recording_id]
        usage_unit = records[overage.usage_unit_recording_id]
        unless option.is_a?(BillingOption) && market.is_a?(Market) && usage_unit.is_a?(UsageUnit)
          raise ArgumentError,
                "overage has incomplete references"
        end
        unless overage.pricing_model == option.pricing_model
          raise ArgumentError,
                "overage pricing model does not match billing option"
        end
        unless market.allowed_currency_codes.include?(overage.currency_code)
          raise ArgumentError,
                "overage currency is not permitted by market"
        end
        product = records[option.product_recording_id]
        unless usage_unit.provider_account_recording_id == product.provider_account_recording_id
          raise ArgumentError,
                "overage usage unit provider does not match product provider"
        end
      end
    end

    def validate_rules!(rules, records, prices)
      selected_product_ids = prices.map do |price|
        records.fetch(price.billing_option_recording_id).product_recording_id
      end
      rules.each do |rule|
        target = records[rule.target_product_recording_id]
        raise ArgumentError, "product rule target is missing or outside the selected graph" unless target.is_a?(Product)
        next if target.state == "published" || selected_product_ids.include?(target.recording.id)

        raise ArgumentError, "product rule targets must be published or selected for publication"
      end
    end

    def validate_current_version!(record)
      duplicate = current_identity_scope(record).where(version: record.version)
                                                .where.not(recording_studio_recordings: { id: record.recording.id })
                                                .exists?
      raise ArgumentError, "commercial price version is already used" if duplicate
    end

    def current_identity_scope(record)
      record.class.with_current_recording.where(price_identity(record))
    end

    def price_identity(record)
      identity = {
        billing_option_recording_id: record.billing_option_recording_id,
        scope: record.scope,
        market_recording_id: record.market_recording_id,
        currency_code: record.currency_code
      }
      identity[:usage_unit_recording_id] = record.usage_unit_recording_id if record.is_a?(OveragePrice)
      identity
    end

    def validate_replacements!(records)
      replacements.each do |replacement_id, prior_id|
        replacement = records.fetch(replacement_id)
        prior = records.fetch(prior_id)
        unless (replacement.is_a?(Price) && prior.is_a?(Price)) ||
               (replacement.is_a?(OveragePrice) && prior.is_a?(OveragePrice))
          raise ArgumentError, "replacement identities must have the same type"
        end
        raise ArgumentError, "replacement price must be draft" unless replacement.state == "draft"
        raise ArgumentError, "prior price must be published" unless prior.state == "published"

        identity = %i[billing_option_recording_id scope market_recording_id currency_code]
        identity << :usage_unit_recording_id if replacement.is_a?(OveragePrice)
        raise ArgumentError, "replacement price identity does not match prior price" unless identity.all? do |name|
          replacement.public_send(name) == prior.public_send(name)
        end

        unless replacement.version > prior.version
          raise ArgumentError,
                "replacement price version must be greater than prior price version"
        end
      end
    end

    def persist_manifests(root, graph)
      prices = selected_prices(root)
      records = graph.index_by { |record| record.recording.id }
      prices.map { |price| persist_manifest(root, graph, records, price) }
    end

    def persist_manifest(root, graph, records, price)
      option = records.fetch(price.billing_option_recording_id)
      market = records.fetch(price.market_recording_id)
      overages = graph.grep(OveragePrice).select do |overage|
        overage.billing_option_recording_id == price.billing_option_recording_id &&
          overage.market_recording_id == price.market_recording_id &&
          overage.currency_code == price.currency_code && overage.scope == price.scope
      end
      resolver = CommercialManifestResolver.new(
        product: records.fetch(option.product_recording_id),
        billing_option: option,
        price: price,
        market: market,
        currency_code: price.currency_code,
        overage_prices: overages,
        publication_candidate: true
      )
      persist_manifest_result(root, resolver.resolve!)
    end

    def persist_manifest_result(root, result)
      existing = CommercialManifest.find_by(manifest_digest: result.fetch(:manifest_digest))
      return existing if existing

      CommercialManifest.create! do |manifest|
        manifest.root_recording_id = root.id
        manifest.schema_version = SUPPORTED_MANIFEST_SCHEMA
        manifest.resolver_version = SUPPORTED_RESOLVER_VERSION
        manifest.manifest_digest = result.fetch(:manifest_digest)
        manifest.canonical_data = result.fetch(:canonical_data)
        manifest.recording_snapshots = result.fetch(:recording_snapshots)
        manifest.snapshot_references = result.fetch(:snapshot_references)
      end
    end

    def snapshot_envelope(root, graph, manifests)
      snapshots = graph.map { |record| snapshot(record) }.sort.to_h
      {
        "schema_version" => SUPPORTED_MANIFEST_SCHEMA,
        "resolver_version" => SUPPORTED_RESOLVER_VERSION,
        "root_recording_id" => root.id,
        "effective_at" => effective_at.utc.iso8601(6),
        "selection" => {
          "price_recording_ids" => selected_prices(root).map { |price| price.recording.id }.sort,
          "replacements" => replacements.sort.to_h
        },
        "recordings" => snapshots,
        "manifests" => manifests.sort_by(&:manifest_digest).map do |manifest|
          { "manifest_digest" => manifest.manifest_digest, "schema_version" => manifest.schema_version,
            "resolver_version" => manifest.resolver_version, "canonical_data" => manifest.canonical_data,
            "recording_snapshots" => manifest.recording_snapshots,
            "snapshot_references" => manifest.snapshot_references }
        end
      }
    end

    def snapshot(record)
      recording = record.recording
      [recording.id, {
        "recording_id" => recording.id, "root_recording_id" => recording.root_recording_id,
        "parent_recording_id" => recording.parent_recording_id, "recordable_type" => recording.recordable_type,
        "recordable_id" => recording.recordable_id, "recording_created_at" => recording.created_at.utc.iso8601(6),
        "recording_updated_at" => recording.updated_at.utc.iso8601(6),
        "recording_trashed_at" => recording.attributes["trashed_at"]&.utc&.iso8601(6),
        "recordable_created_at" => record.created_at.utc.iso8601(6),
        "recordable_updated_at" => record.updated_at.utc.iso8601(6),
        "recordable_digest" => CommercialManifestCanonicalizer.digest(
          record.attributes.except("created_at", "updated_at")
        )
      }]
    end

    def find_or_create_candidate!(root, manifests, envelope)
      digest = CommercialManifestCanonicalizer.digest(envelope)
      existing = CommercialPublicationCandidate.lock.find_by(root_recording_id: root.id, effective_at: effective_at)
      if existing
        unless existing.candidate_digest == digest
          raise ArgumentError,
                "effective time is already used by a different publication"
        end

        return existing
      end

      CommercialPublicationCandidate.create!(
        root_recording_id: root.id, effective_at: effective_at, candidate_digest: digest,
        manifest_digests: manifests.map(&:manifest_digest).sort, recording_snapshots: envelope.fetch("recordings"),
        snapshot_envelope: envelope
      )
    end

    def verify_candidate!(publication)
      envelope = publication.snapshot_envelope
      raise ArgumentError, "publication candidate envelope is invalid" unless envelope.is_a?(Hash)

      unless envelope["schema_version"] == SUPPORTED_MANIFEST_SCHEMA &&
             envelope["resolver_version"] == SUPPORTED_RESOLVER_VERSION
        raise ArgumentError,
              "unsupported publication candidate version"
      end
      unless envelope["root_recording_id"] == publication.root_recording_id &&
             envelope["effective_at"] == publication.effective_at.utc.iso8601(6)
        raise ArgumentError, "publication candidate envelope does not match its persisted terms"
      end

      unless CommercialManifestCanonicalizer.digest(envelope) == publication.candidate_digest
        raise ArgumentError,
              "publication candidate digest mismatch"
      end
      unless publication.recording_snapshots == envelope["recordings"]
        raise ArgumentError,
              "publication candidate snapshots differ from envelope"
      end

      manifests = CommercialManifest.where(manifest_digest: publication.manifest_digests)
                                    .order(:manifest_digest).lock.to_a
      unless manifests.size == publication.manifest_digests.size
        raise ArgumentError,
              "publication candidate manifests are missing"
      end
      raise ArgumentError, "publication candidate manifests cross roots" unless manifests.all? do |manifest|
        manifest.root_recording_id == publication.root_recording_id
      end

      expected_manifests = envelope.fetch("manifests").index_by { |item| item.fetch("manifest_digest") }
      manifests.each do |manifest|
        expected = expected_manifests[manifest.manifest_digest]
        raise ArgumentError, "publication candidate manifest is missing from envelope" unless expected

        unless manifest.schema_version == SUPPORTED_MANIFEST_SCHEMA &&
               manifest.resolver_version == SUPPORTED_RESOLVER_VERSION
          raise ArgumentError,
                "unsupported commercial manifest version"
        end

        actual = {
          "schema_version" => manifest.schema_version,
          "resolver_version" => manifest.resolver_version,
          "root_recording_id" => manifest.root_recording_id,
          "canonical_data" => manifest.canonical_data,
          "recording_snapshots" => manifest.recording_snapshots,
          "snapshot_references" => manifest.snapshot_references
        }
        next if CommercialManifestCanonicalizer.digest(actual) == manifest.manifest_digest &&
                expected.except("manifest_digest") == actual.except("root_recording_id")

        raise ArgumentError,
              "commercial manifest envelope mismatch"
      end

      snapshots = envelope.fetch("recordings")
      unless snapshots.values.all? { |snapshot| snapshot["root_recording_id"] == publication.root_recording_id }
        raise ArgumentError, "publication candidate snapshots cross roots"
      end

      recordings = RecordingStudio::Recording.unscoped.where(id: snapshots.keys).order(:id).lock.to_a
      recordings.group_by(&:recordable_type).each do |type, rows|
        type.constantize.where(id: rows.map(&:recordable_id)).order(:id).lock.load
      end
      recordings.each do |recording|
        verify_snapshot!(recording, snapshots.fetch(recording.id))
      end
      return if snapshots.keys.sort == RecordingStudio::Recording.unscoped.where(id: snapshots.keys).pluck(:id).sort

      raise ArgumentError,
            "publication candidate recording is missing"
    end

    def verify_snapshot!(recording, expected)
      record = recording.recordable
      actual = snapshot(record).last
      raise ArgumentError, "publication candidate is stale or tampered" unless actual == expected
    end

    def activate_candidate!(publication)
      verify_candidate!(publication)
      envelope = publication.snapshot_envelope
      records = envelope.fetch("recordings").keys.sort.map { |id| RecordingStudio::Recording.unscoped.lock.find(id) }
      replacements_for(envelope).each do |prior|
        prior.recording.root_recording.revise(
          prior.recording, metadata: { "commercial_candidate_digest" => publication.candidate_digest }
        ) { |revision| revision.state = "retired" }
      end
      records.each do |recording|
        record = recording.recordable
        next unless record.respond_to?(:state) && record.state == "draft"

        recording.root_recording.revise(
          recording, metadata: { "commercial_candidate_digest" => publication.candidate_digest }
        ) { |revision| revision.state = "published" }
      end
      CommercialManifest.where(manifest_digest: publication.manifest_digests).order(:id).each(&:mark_used!)
      publication.update!(activated_at: Time.current)
      records.each do |recording|
        recording.reload.log_event!(
          action: "commercial_published",
          metadata: { "candidate_digest" => publication.candidate_digest }
        )
      end
      publication
    end

    def replacements_for(envelope)
      envelope.dig("selection", "replacements").to_h.values.map do |recording_id|
        recording = RecordingStudio::Recording.unscoped.lock.find(recording_id)
        record = recording.recordable
        unless record.is_a?(Price) || record.is_a?(OveragePrice)
          raise ArgumentError,
                "replacement reference must be a Price or OveragePrice"
        end

        record
      end
    end

    def candidate_or_id
      candidate.respond_to?(:id) ? candidate.id : candidate
    end
  end
end
