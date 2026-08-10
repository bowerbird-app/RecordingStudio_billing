# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Lint/MissingCopEnableDirective

module RecordingStudioBilling
  class CommercialPublisher
    RECORDABLE_TYPES = %w[
      ProviderAccount Market Product BillingOption Price OveragePrice Feature ProductRule UsageUnit
    ].freeze.map { |name| "RecordingStudioBilling::#{name}" }.freeze

    def self.publish!(...)
      new(...).publish!
    end

    def self.activate!(...)
      new(...).activate!
    end

    def initialize(root_recording: nil, effective_at: Time.current, candidate: nil)
      @root_recording = root_recording
      @effective_at = effective_at
      @candidate = candidate
    end

    def publish!
      CommercialPublicationCandidate.transaction do
        root = canonical_root!
        recordings = lock_recordings(root)
        validate_root!(root, recordings)
        validate_graph!(root, recordings)
        manifests = build_and_persist_manifests(root, recordings)
        candidate = create_candidate(root, manifests, recordings)
        activate_candidate!(candidate) if effective_at <= Time.current
        candidate
      end
    end

    def activate!
      CommercialPublicationCandidate.transaction do
        candidate = CommercialPublicationCandidate.lock.find(candidate_or_id)
        return candidate if candidate.activated?
        raise ArgumentError, "publication candidate is not effective yet" if candidate.effective_at > Time.current

        verify_candidate!(candidate)
        activate_candidate!(candidate)
      end
    end

    private

    attr_reader :root_recording, :effective_at, :candidate

    def canonical_root!
      root = RecordingStudio.root_recording_or_self(root_recording)
      RecordingStudio.assert_root_recording!(root)
      RecordingStudio::Recording.unscoped.lock.find(root.id)
    end

    def lock_recordings(root)
      RecordingStudio::Recording.unscoped
                                .where(root_recording_id: root.id, recordable_type: RECORDABLE_TYPES)
                                .order(:id).lock.to_a
    end

    def validate_root!(root, recordings)
      admin = BillingAdmin.find_by!(root_recording_id: root.id)
      admin_recording = admin.recording
      unless admin_recording.parent_recording_id == root.id
        raise ArgumentError,
              "billing administration is not under its root"
      end
      raise ArgumentError, "commercial records are required" if recordings.empty?
      raise ArgumentError, "commercial recording has wrong root" unless recordings.all? do |recording|
        recording.root_recording_id == root.id
      end
    end

    def validate_graph!(_root, recordings)
      recordables = recordings.index_by(&:id).transform_values(&:recordable)
      validate_recording_parents!(recordings, recordables)
      validate_provider_consistency!(recordables)
      validate_prices!(recordables)
      validate_features_and_rules!(recordables)
      raise ArgumentError, "no publishable draft price exists" if publishable_prices(recordables).empty?
    end

    def validate_recording_parents!(recordings, recordables)
      recordings.each do |recording|
        recordable = recordables.fetch(recording.id)
        allowed = Array(RecordingStudio.allowed_parent_types_for(recordable.class))
        parent_type = recording.parent_recording&.recordable_type
        next if allowed.include?(parent_type)

        raise ArgumentError, "#{recordable.class.name} has an invalid recording parent"
      end
    end

    def validate_provider_consistency!(recordables)
      markets = recordables.values.grep(Market)
      products = recordables.values.grep(Product)
      providers = recordables.values.grep(ProviderAccount).index_by { |provider| provider.recording.id }
      (markets + products).each do |record|
        provider = providers.fetch(record.provider_account_recording_id) do
          raise ArgumentError, "missing provider account"
        end
        raise ArgumentError, "provider account is not publishable" unless %w[draft published].include?(provider.state)
      end
      markets.each do |market|
        provider = providers.fetch(market.provider_account_recording_id)
        unless Array(market.country_codes).all? do |country|
          provider.supported_markets.empty? || provider.supported_markets.include?(country)
        end
          raise ArgumentError, "market country is unsupported by provider"
        end
        next if Array(market.allowed_currency_codes).all? do |currency|
          provider.supported_currencies.empty? || provider.supported_currencies.include?(currency)
        end

        raise ArgumentError, "market currency is unsupported by provider"
      end
    end

    def validate_prices!(recordables)
      prices = recordables.values.grep(Price)
      identity = lambda { |price|
        [price.billing_option_recording_id, price.scope, price.market_recording_id, price.currency_code]
      }
      duplicates = prices.select do |price|
        price.state == "published"
      end.group_by(&identity).values.any? { |items| items.size > 1 }
      raise ArgumentError, "multiple active prices share an identity" if duplicates

      prices.each do |price|
        option = recordables[price.billing_option_recording_id]
        market = recordables[price.market_recording_id]
        unless option.is_a?(BillingOption) && market.is_a?(Market)
          raise ArgumentError,
                "price has incomplete billing option or market reference"
        end

        product = recordables[option.product_recording_id]
        unless product&.provider_account_recording_id == market.provider_account_recording_id
          raise ArgumentError,
                "price graph crosses provider accounts"
        end
        unless market.allowed_currency_codes.include?(price.currency_code)
          raise ArgumentError,
                "price currency is not permitted by market"
        end
      end
    end

    def validate_features_and_rules!(recordables)
      recordables.values.grep(Feature).each { |feature| FeatureDefinitionRegistry.fetch!(feature.key) }
      recordables.values.grep(ProductRule).each do |rule|
        raise ArgumentError, "product rule target is required" if rule.target_product_recording_id.blank?

        unless recordables[rule.target_product_recording_id].is_a?(Product)
          raise ArgumentError,
                "product rule target is missing"
        end
      end
    end

    def build_and_persist_manifests(root, recordings)
      recordables = recordings.index_by(&:id).transform_values(&:recordable)
      publishable_prices(recordables).map do |price|
        option = recordables.fetch(price.billing_option_recording_id)
        product = recordables.fetch(option.product_recording_id)
        market = recordables.fetch(price.market_recording_id)
        overage = matching_overage(recordables, price)
        result = CommercialManifestResolver.new(
          product: product, billing_option: option, price: price, market: market,
          currency_code: price.currency_code, overage_price: overage, publication_candidate: true
        ).resolve!
        CommercialManifest.create!(
          root_recording_id: root.id, schema_version: CommercialManifest::SCHEMA_VERSION,
          resolver_version: CommercialManifest::RESOLVER_VERSION, **result
        )
      rescue ActiveRecord::RecordNotUnique
        CommercialManifest.find_by!(manifest_digest: result.fetch(:manifest_digest))
      end
    end

    def matching_overage(recordables, price)
      recordables.values.grep(OveragePrice).find do |overage|
        overage.billing_option_recording_id == price.billing_option_recording_id &&
          overage.market_recording_id == price.market_recording_id &&
          overage.currency_code == price.currency_code && %w[draft published].include?(overage.state)
      end
    end

    def create_candidate(root, manifests, recordings)
      snapshots = recordings.map do |recording|
        recordable = recording.recordable
        {
          "recording_id" => recording.id,
          "recordable_type" => recording.recordable_type,
          "recordable_id" => recording.recordable_id,
          "recordable_updated_at" => recordable.updated_at.utc.iso8601(6)
        }
      end.sort_by { |snapshot| snapshot.fetch("recording_id") }
      digest = CommercialManifestCanonicalizer.digest(
        "root_recording_id" => root.id, "effective_at" => effective_at, "manifest_digests" => manifests.map(&:manifest_digest).sort,
        "recording_snapshots" => snapshots
      )
      CommercialPublicationCandidate.create!(
        root_recording_id: root.id, effective_at: effective_at, candidate_digest: digest,
        manifest_digests: manifests.map(&:manifest_digest).sort, recording_snapshots: snapshots
      )
    rescue ActiveRecord::RecordNotUnique
      CommercialPublicationCandidate.find_by!(candidate_digest: digest)
    end

    def verify_candidate!(candidate)
      expected = CommercialManifestCanonicalizer.digest(
        "root_recording_id" => candidate.root_recording_id, "effective_at" => candidate.effective_at,
        "manifest_digests" => candidate.manifest_digests.sort, "recording_snapshots" => candidate.recording_snapshots.sort_by do |snapshot|
                                                                 snapshot.fetch("recording_id")
                                                               end
      )
      raise ArgumentError, "publication candidate digest mismatch" unless expected == candidate.candidate_digest

      manifests = CommercialManifest.where(manifest_digest: candidate.manifest_digests)
      unless manifests.count == candidate.manifest_digests.size
        raise ArgumentError,
              "publication candidate manifests are missing"
      end
      unless manifests.all? do |manifest|
        manifest.schema_version == CommercialManifest::SCHEMA_VERSION &&
        manifest.resolver_version == CommercialManifest::RESOLVER_VERSION
      end
        raise ArgumentError, "publication candidate uses an unsupported manifest version"
      end
      raise ArgumentError, "publication candidate manifest digest mismatch" unless manifests.all? do |manifest|
        CommercialManifestCanonicalizer.digest(manifest.canonical_data) == manifest.manifest_digest
      end

      candidate.recording_snapshots.each do |snapshot|
        recording = RecordingStudio::Recording.find(snapshot.fetch("recording_id"))
        recordable = recording.recordable
        unless recording.recordable_type == snapshot.fetch("recordable_type") &&
               recording.recordable_id == snapshot.fetch("recordable_id")
          raise ArgumentError, "publication candidate recording snapshot mismatch"
        end

        unless recordable.updated_at.utc.iso8601(6) == snapshot.fetch("recordable_updated_at")
          raise ArgumentError,
                "publication candidate is stale"
        end
      end
    end

    def activate_candidate!(candidate)
      manifests = CommercialManifest.where(manifest_digest: candidate.manifest_digests)
      recordings = candidate.recording_snapshots.map { |snapshot| RecordingStudio::Recording.find(snapshot.fetch("recording_id")) }
      recordings.sort_by(&:id).each do |recording|
        next unless recording.recordable.respond_to?(:state) && recording.recordable.state == "draft"

        recording.root_recording.revise(recording,
                                        metadata: { "commercial_candidate_digest" => candidate.candidate_digest }) do |revision|
          revision.state = "published"
          revision.key = "#{revision.key}_#{candidate.candidate_digest.first(8)}" if revision.respond_to?(:key)
          revision.version += 1 if revision.is_a?(Price) || revision.is_a?(OveragePrice)
          if revision.is_a?(Feature)
            revision.definition = revision.definition.merge("_commercial_source_key" => recording.recordable.key)
          end
        end
      end
      manifests.each(&:mark_used!)
      candidate.update!(activated_at: Time.current)
      record_publication_event!(candidate, recordings)
      candidate
    end

    def record_publication_event!(candidate, recordings)
      recordings.each do |recording|
        recording.log_event!(
          action: "commercial_published",
          metadata: { "candidate_digest" => candidate.candidate_digest }
        )
      end
    end

    def publishable_prices(recordables)
      recordables.values.grep(Price).select { |price| price.state == "draft" }
    end

    def candidate_or_id
      candidate.respond_to?(:id) ? candidate.id : candidate
    end
  end
end
