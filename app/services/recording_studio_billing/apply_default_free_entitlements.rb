# frozen_string_literal: true

module RecordingStudioBilling
  class ApplyDefaultFreeEntitlements
    Result = Data.define(:bootstrap, :grants, :existing?)

    def self.call(...) = new(...).call

    def initialize(root_recording:, account_recording: nil, product_key: nil, location_context: nil, optional: false)
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @account_recording = account_recording
      @product_key = product_key
      @location_context = location_context
      @optional = optional == true
    end

    def call
      return skipped unless configured?

      DefaultEntitlementBootstrap.transaction do
        root = RecordingStudio::Recording.unscoped.find(root_recording.id).lock!
        account = resolve_account(root)
        existing = DefaultEntitlementBootstrap.find_by(root_recording: root, account_recording: account)
        return Result.new(bootstrap: existing, grants: grants_for(existing), existing?: true) if existing

        plan = resolve_plan!(root:, account:)
        bootstrap = DefaultEntitlementBootstrap.create!(
          root_recording: root,
          account_recording: account,
          product_key: plan.product.key,
          manifest_digest: plan.manifest_digest,
          commercial_snapshot: plan.commercial_snapshot,
          applied_at: Time.current
        )
        grants = project_grants!(bootstrap, plan.commercial_snapshot)
        account.reload.log_event!(
          action: "default_free_entitlements_applied",
          metadata: {
            "product_key" => plan.product.key,
            "manifest_digest" => plan.manifest_digest
          }
        )
        Result.new(bootstrap:, grants:, existing?: false)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    rescue ActiveRecord::RecordNotFound, ArgumentError
      raise unless optional

      skipped
    end

    private

    attr_reader :account_recording, :location_context, :optional, :product_key, :root_recording

    def configured?
      (product_key || RecordingStudioBilling.configuration.default_free_plan_product_key).present?
    end

    def skipped
      Result.new(bootstrap: nil, grants: [], existing?: true)
    end

    def resolve_account(root)
      recording = account_recording || Account.with_current_recording.find_by!(root_recording: root).recording
      unless recording.recordable_type == "RecordingStudioBilling::Account" &&
             recording.root_recording_id == root.id && recording.parent_recording_id == root.id
        raise ArgumentError, "entitlement account authority is invalid"
      end

      recording
    end

    def resolve_plan!(root:, account:)
      ResolveDefaultFreePlan.call(root_recording: root, account_recording: account, product_key:, location_context:)
    end

    def grants_for(bootstrap)
      return [] unless bootstrap

      EntitlementGrant.where(source_type: bootstrap.class.name, source_id: bootstrap.id).order(:id).to_a
    end

    def project_grants!(bootstrap, snapshot)
      features = snapshot.fetch("canonical_data").fetch("features")
      features.map do |feature_key, feature|
        EntitlementGrant.find_or_create_by!(
          root_recording: bootstrap.root_recording,
          source_type: bootstrap.class.name,
          source_id: bootstrap.id,
          feature_key:
        ) do |grant|
          grant.account_recording = bootstrap.account_recording
          grant.manifest_digest = bootstrap.manifest_digest
          grant.feature_kind = feature.fetch("definition").fetch("type")
          grant.merge_rule = feature.fetch("definition").fetch("merge_rule")
          grant.value = feature.fetch("value")
          grant.projected_at = bootstrap.applied_at
        end
      end
    end
  end
end
