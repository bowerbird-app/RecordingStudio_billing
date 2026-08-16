# frozen_string_literal: true

module RecordingStudioBilling
  class OverviewPresenter < BasePresenter
    attr_accessor :subscriptions, :checkout_intents

    def page = :overview

    def subscription_rows
      ordered_subscriptions.map do |subscription|
        versions = subscription.item_versions.where(effective_ends_at: nil).order(:line_key)
        primary = versions.first
        terms = canonical_terms(primary&.commercial_snapshot)
        {
          subscription:,
          identifier: subscription.identifier,
          label: subscription_label(primary, terms),
          state: money_state(subscription.state),
          current: current_plan?(subscription),
          summary: versions.map { |version| version_summary(version) }.join("; ")
        }
      end
    end

    private

    def ordered_subscriptions
      subscriptions.sort_by { |subscription| current_plan?(subscription) ? 0 : 1 }
    end

    def current_plan?(subscription)
      subscription.state.to_s.in?(%w[trialing active past_due paused])
    end

    def subscription_label(version, terms)
      return copy("plan_title", "Plan") unless version

      offer_label(
        kind: snapshot_value(terms, "product", "kind") || "plan",
        interval: version.interval,
        recurrence: snapshot_value(terms, "billing_option", "recurrence"),
        name: snapshot_value(terms, "product", "name"),
        amount_minor: version.amount_minor
      )
    end

    def version_summary(version)
      terms = canonical_terms(version.commercial_snapshot)
      label = offer_label(
        kind: snapshot_value(terms, "product", "kind") || "plan",
        interval: version.interval,
        recurrence: snapshot_value(terms, "billing_option", "recurrence"),
        name: snapshot_value(terms, "product", "name"),
        amount_minor: version.amount_minor
      )
      cadence = cadence_label(snapshot_value(terms, "billing_option", "recurrence") || "recurring", version.interval)
      "#{label}: #{version.quantity} x #{display_amount(version.amount_minor, version.currency_code)} #{cadence}"
    end
  end
end
