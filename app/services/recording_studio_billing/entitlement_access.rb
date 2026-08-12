# frozen_string_literal: true

module RecordingStudioBilling
  class EntitlementAccess
    class AmbiguousVariant < ArgumentError; end

    def self.for(...) = new(...)

    def initialize(root_recording:, account_recording: nil, at: Time.current)
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @account_recording = account_recording || Account.with_current_recording.find_by!(root_recording: @root_recording).recording
      @at = at
      verify_authority!
    end

    def enabled?(feature_key) = boolean(feature_key)

    def boolean(feature_key)
      values_for(feature_key, "boolean").any? { |value| value == true }
    end

    def limit(feature_key) = numeric(feature_key, "limit")
    def allowance(feature_key) = numeric(feature_key, "allowance")

    def variant(feature_key)
      values = values_for(feature_key, "variant").uniq
      raise AmbiguousVariant, "entitlement variant is ambiguous for #{feature_key}" if values.many?

      values.first
    end

    def credit_balance(credit_key)
      CreditLedgerEntry.where(root_recording: root_recording, account_recording:, product_recording_id: credit_key)
                       .where(effective_at: ..at).sum(:amount)
    end

    def feature_value(feature_key)
      kinds = effective_grants.where(feature_key:).distinct.pluck(:feature_kind)
      return nil if kinds.empty?
      raise ArgumentError, "entitlement feature kind is ambiguous for #{feature_key}" if kinds.many?

      public_send(kinds.first == "boolean" ? :boolean : kinds.first, feature_key)
    end

    def to_h
      effective_grants.distinct.pluck(:feature_key).sort.to_h { |feature_key| [feature_key, feature_value(feature_key)] }
    end

    private

    attr_reader :account_recording, :root_recording, :at

    def verify_authority!
      unless account_recording.recordable_type == "RecordingStudioBilling::Account" &&
             account_recording.root_recording_id == root_recording.id && account_recording.parent_recording_id == root_recording.id
        raise ArgumentError, "entitlement account authority is invalid"
      end
    end

    def numeric(feature_key, kind)
      grants = grants_for(feature_key, kind)
      values = grants.map(&:value)
      return nil if values.empty?

      rule = merge_rule_for!(grants, feature_key)
      numeric_values = values.map do |value|
        Integer(value)
      rescue ArgumentError, TypeError
        raise ArgumentError, "entitlement #{kind} must be an integer"
      end
      case rule
      when "maximum" then numeric_values.max
      when "minimum" then numeric_values.min
      when "replace"
        raise ArgumentError, "entitlement #{kind} replace values conflict for #{feature_key}" if numeric_values.uniq.many?

        numeric_values.first
      else
        raise ArgumentError, "entitlement #{kind} does not support #{rule} merge for #{feature_key}"
      end
    end

    def values_for(feature_key, kind)
      grants_for(feature_key, kind).map(&:value)
    end

    def grants_for(feature_key, kind)
      effective_grants.where(feature_key:, feature_kind: kind).order(:id).to_a
    end

    def merge_rule_for!(grants, feature_key)
      rules = grants.map(&:merge_rule).uniq
      raise ArgumentError, "entitlement merge rules conflict for #{feature_key}" if rules.many?

      rules.first
    end

    def effective_grants
      grants = EntitlementGrant.where(root_recording:, account_recording:)
      subscription_ids = active_subscription_source_ids
      purchase_effect_ids = PurchaseEffect.where(root_recording:, account_recording:).where(effective_at: ..at).select(:id)
      grants.where(source_type: "RecordingStudioBilling::SubscriptionItemVersion", source_id: subscription_ids)
            .or(grants.where(source_type: "RecordingStudioBilling::PurchaseEffect", source_id: purchase_effect_ids))
    end

    def active_subscription_source_ids
      SubscriptionItemVersion.joins(:subscription)
                             .where(root_recording:, account_recording:, effective_starts_at: ..at)
                             .where("recording_studio_billing_subscription_item_versions.effective_ends_at IS NULL OR recording_studio_billing_subscription_item_versions.effective_ends_at > ?", at)
                             .where(recording_studio_billing_subscriptions: { state: %w[trialing active] })
                             .select(:id)
    end
  end
end