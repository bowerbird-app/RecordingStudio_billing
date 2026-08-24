# frozen_string_literal: true

module RecordingStudioBilling
  class OverviewPresenter < BasePresenter
    attr_accessor :subscriptions, :checkout_intents

    def page = :overview

    def subscription_rows
      ordered_subscriptions.map do |subscription|
        lines = current_subscription_lines(subscription)
        primary = lines.first
        terms = canonical_terms(primary&.commercial_snapshot)
        {
          subscription:,
          identifier: subscription.identifier,
          label: subscription_label(primary, terms),
          state: money_state(subscription.state),
          current: current_plan?(subscription),
          price_label: primary && customer_price(primary.amount_minor, primary.currency_code),
          price_suffix: price_interval_suffix(primary&.interval),
          cadence: primary && cadence_label(snapshot_value(terms, "billing_option", "recurrence") || "recurring",
                                            primary.interval),
          summary: lines.map { |line| line_summary(line) }.join("; ")
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

    def subscription_label(line, terms)
      return copy("plan_title", "Plan") unless line

      offer_label(
        kind: snapshot_value(terms, "product", "kind") || "plan",
        interval: line.interval,
        recurrence: snapshot_value(terms, "billing_option", "recurrence"),
        name: snapshot_value(terms, "product", "name"),
        key: snapshot_value(terms, "product", "key"),
        amount_minor: line.amount_minor
      )
    end

    def line_summary(line)
      terms = canonical_terms(line.commercial_snapshot)
      label = offer_label(
        kind: snapshot_value(terms, "product", "kind") || "plan",
        interval: line.interval,
        recurrence: snapshot_value(terms, "billing_option", "recurrence"),
        name: snapshot_value(terms, "product", "name"),
        key: snapshot_value(terms, "product", "key"),
        amount_minor: line.amount_minor
      )
      cadence = cadence_label(snapshot_value(terms, "billing_option", "recurrence") || "recurring", line.interval)
      "#{label}: #{line.quantity} x #{display_amount(line.amount_minor, line.currency_code)} #{cadence}"
    end
  end
end
