# frozen_string_literal: true

module RecordingStudioBilling
  class ProjectEntitlements
    Result = Data.define(:grants, :credit_entries, :existing?)

    def self.call(...) = new(...).call

    def initialize(root_recording:, source: nil)
      @source_input = source
      @root_recording_input = root_recording
    end

    def call
      EntitlementGrant.transaction do
        root = RecordingStudio.root_recording_or_self(root_recording_input).lock!
        sources_for(root).map { |source| project_source(source, root) }.then do |projected|
          Result.new(grants: projected.flat_map(&:first), credit_entries: projected.flat_map(&:last),
                     existing?: projected.empty?)
        end
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    attr_reader :source_input, :root_recording_input

    def sources_for(root)
      return [resolve_source(root)] if source_input

      SubscriptionItemVersion.where(root_recording: root).order(:id).lock.to_a +
        PurchaseEffect.where(root_recording: root).order(:id).lock.to_a
    end

    def resolve_source(root)
      raise ArgumentError, "entitlement source must be a subscription item version or purchase effect" unless source_input.is_a?(SubscriptionItemVersion) || source_input.is_a?(PurchaseEffect)

      unless source_input.root_recording_id == root.id
        raise ActiveRecord::RecordNotFound,
              "entitlement source not found"
      end

      source_input.lock!
    end

    def verify_source!(source, root)
      raise ActiveRecord::RecordNotFound, "entitlement source not found" unless source.root_recording_id == root.id

      account = source.account_recording
      unless account.recordable_type == "RecordingStudioBilling::Account" && account.root_recording_id == root.id &&
             account.parent_recording_id == root.id && account.recordable.root_recording_id == root.id
        raise ArgumentError, "entitlement account authority is invalid"
      end

      SafeFinancialPayload.validate!(snapshot(source))
      manifest = CommercialManifest.lock.find_by!(manifest_digest: source.manifest_digest)
      envelope = {
        "schema_version" => manifest.schema_version, "resolver_version" => manifest.resolver_version,
        "root_recording_id" => manifest.root_recording_id, "canonical_data" => manifest.canonical_data,
        "recording_snapshots" => manifest.recording_snapshots, "snapshot_references" => manifest.snapshot_references
      }
      unless manifest.used_at? && CommercialManifestCanonicalizer.digest(envelope) == source.manifest_digest &&
             snapshot(source).fetch("canonical_data") == manifest.canonical_data
        raise ArgumentError, "entitlement frozen manifest is invalid"
      end
      return unless source.is_a?(PurchaseEffect) && source.purchase.manifest_digest != source.manifest_digest

      raise ArgumentError, "entitlement purchase effect manifest is invalid"
    end

    def snapshot(source)
      source.is_a?(PurchaseEffect) ? source.purchase.commercial_snapshot : source.commercial_snapshot
    end

    def features(source)
      snapshot(source).fetch("canonical_data").fetch("features").tap do |features|
        features.each do |key, feature|
          definition = feature.fetch("definition")
          raise ArgumentError, "entitlement feature kind is invalid" unless Feature::TYPES.include?(definition.fetch("type"))

          SafeFinancialPayload.validate!({ key => feature })
        end
      end
    end

    def project_credits(source, root)
      return [] unless source.is_a?(PurchaseEffect) && source.effect_kind == "credit_pack"

      features(source).filter_map do |credit_key, feature|
        next unless feature.dig("definition", "type") == "allowance"

        amount = Integer(feature.fetch("value")) * source.purchase.quantity
        CreditLedgerEntry.find_or_create_by!(purchase_effect: source, credit_key:) do |entry|
          entry.root_recording = root
          entry.account_recording = source.account_recording
          entry.product_recording_id = source.purchase.product_recording_id
          entry.manifest_digest = source.manifest_digest
          entry.amount = amount
          entry.effective_at = source.effective_at
        end
      end
    rescue ArgumentError, TypeError
      raise ArgumentError, "credit allowance must be an integer"
    end

    def project_source(source, root)
      verify_source!(source, root)
      grants = features(source).map do |feature_key, feature|
        EntitlementGrant.find_or_create_by!(root_recording: root, source_type: source.class.name,
                                            source_id: source.id, feature_key:) do |grant|
          grant.account_recording = source.account_recording
          grant.manifest_digest = source.manifest_digest
          grant.feature_kind = feature.fetch("definition").fetch("type")
          grant.merge_rule = feature.fetch("definition").fetch("merge_rule")
          grant.value = feature.fetch("value")
          grant.projected_at = Time.current
        end
      end
      [grants, project_credits(source, root)]
    end
  end
end
