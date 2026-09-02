# frozen_string_literal: true

module RecordingStudioBilling
  class EntitlementAccess
    class AmbiguousVariant < ArgumentError; end
    class UnknownMeter < ArgumentError; end

    def self.for(...) = new(...)

    def initialize(root_recording:, account_recording: nil, at: Time.current)
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @account_recording = account_recording || Account.with_current_recording.find_by!(root_recording: @root_recording).recording
      @at = at
      verify_authority!
    end

    def enabled?(feature_key) = boolean(feature_key)

    def has_feature?(feature_key)
      effective_grants.where(feature_key:).exists?
    end

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

    def remaining_credits(meter_key)
      meter_credits(meter_key).remaining
    end

    def meter_credits(meter_key)
      key = meter_key.to_s
      raise UnknownMeter, "unknown meter: #{key}" unless nominated_meter?(key)

      grants = grants_for(key, "allowance")
      included = integer_grant_sum(grants.select { |grant| included_meter_source?(grant) })
      purchased = integer_grant_sum(grants.select { |grant| grant.source_type == "RecordingStudioBilling::Purchase" })
      used = usage_total(key)
      remaining = [included + purchased - used, 0].max
      MeterCredits.new(meter_key: key, included:, purchased:, used:, remaining:)
    end

    def nominated_meter_credits
      RecordingStudioBilling.configuration.feature_definitions.keys.filter_map do |key|
        next unless nominated_meter?(key)
        next unless has_feature?(key) || usage_total(key).positive?

        meter_credits(key)
      end
    end

    def usage_total(usage_key, from: nil, to: nil)
      events = UsageEvent.where(root_recording:, account_recording:, usage_key:)
      events = events.where(occurred_at: from..) if from
      events = events.where(occurred_at: ..to) if to
      events.sum(:quantity)
    end

    def feature_value(feature_key)
      kinds = effective_grants.where(feature_key:).distinct.pluck(:feature_kind)
      return nil if kinds.empty?
      raise ArgumentError, "entitlement feature kind is ambiguous for #{feature_key}" if kinds.many?

      public_send(kinds.first == "boolean" ? :boolean : kinds.first, feature_key)
    end

    def to_h
      effective_grants.distinct.pluck(:feature_key).sort.to_h do |feature_key|
        [feature_key, feature_value(feature_key)]
      end
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

      numeric_values = integer_values!(values, kind)
      return numeric_values.sum if kind == "allowance" && nominated_meter?(feature_key)

      rule = merge_rule_for!(grants, feature_key)
      case rule
      when "maximum" then numeric_values.max
      when "minimum" then numeric_values.min
      when "replace"
        if numeric_values.uniq.many?
          raise ArgumentError,
                "entitlement #{kind} replace values conflict for #{feature_key}"
        end

        numeric_values.first
      else
        raise ArgumentError, "entitlement #{kind} does not support #{rule} merge for #{feature_key}"
      end
    end

    def nominated_meter?(feature_key)
      definition = RecordingStudioBilling.configuration.feature_definitions[feature_key.to_s]
      definition && definition["type"] == "allowance" && definition["meter_key"].present?
    end

    def included_meter_source?(grant)
      grant.source_type == "RecordingStudioBilling::SubscriptionLine" ||
        grant.source_type == "RecordingStudioBilling::DefaultEntitlementBootstrap"
    end

    def integer_grant_sum(grants)
      integer_values!(grants.map(&:value), "allowance").sum
    end

    def integer_values!(values, kind)
      values.map do |value|
        Integer(value)
      rescue ArgumentError, TypeError
        raise ArgumentError, "entitlement #{kind} must be an integer"
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
      paid = grants.where(source_type: "RecordingStudioBilling::SubscriptionLine", source_id: subscription_ids)
                   .or(grants.where(source_type: "RecordingStudioBilling::Purchase", source_id: completed_purchase_ids))
      return paid if live_subscription_recording_ids.exists?

      paid.or(grants.where(source_type: "RecordingStudioBilling::DefaultEntitlementBootstrap",
                           source_id: bootstrap_source_ids))
    end

    def bootstrap_source_ids
      DefaultEntitlementBootstrap.where(root_recording:, account_recording:).select(:id)
    end

    # Only the purchase snapshot the Recording points at can grant anything, and
    # only once it has actually completed.
    def completed_purchase_ids
      Purchase.with_current_recording
              .where(root_recording:, account_recording:)
              .where(completed_at: ..at)
              .select("recording_studio_billing_purchases.id")
    end

    # Only the current line snapshot under a live subscription grants anything;
    # superseded and cancelled snapshots keep their grants for the record only.
    def active_subscription_source_ids
      SubscriptionLine.with_current_recording
                      .where(root_recording:, account_recording:, state: "active",
                             subscription_recording_id: live_subscription_recording_ids)
                      .select("recording_studio_billing_subscription_lines.id")
    end

    def live_subscription_recording_ids
      Subscription.for_root(root_recording)
                  .where(account_recording:, state: Subscription::LIVE_STATES)
                  .select("recording_studio_recordings.id")
    end
  end
end
