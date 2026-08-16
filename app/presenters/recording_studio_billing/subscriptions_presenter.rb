# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionsPresenter < BasePresenter
    attr_accessor :subscriptions, :eligible_options, :change_intents

    def page = :subscriptions

    def current_subscription_rows(subscription)
      subscription.item_versions.where(effective_ends_at: nil).order(:line_key).map do |version|
        terms = canonical_terms(version.commercial_snapshot)
        {
          label: offer_label(
            kind: snapshot_value(terms, "product", "kind") || "plan",
            interval: version.interval,
            recurrence: snapshot_value(terms, "billing_option", "recurrence"),
            name: snapshot_value(terms, "product", "name"),
            amount_minor: version.amount_minor
          ),
          quantity: version.quantity,
          amount: display_amount(version.amount_minor, version.currency_code),
          cadence: cadence_label(snapshot_value(terms, "billing_option", "recurrence") || "recurring", version.interval)
        }
      end
    end

    def change_rows(subscription)
      Array(change_intents).select { |intent| intent.subscription_id == subscription.id }.map do |intent|
        {
          label: change_kind_label(intent.change_kind),
          state: money_state(intent.state),
          effective: intent.effective_at&.to_fs(:long) || copy("change_effective_after_confirmation", "After provider confirmation")
        }
      end
    end

    def change_kind_label(kind)
      copy("change_kind_#{kind}", kind.to_s.humanize)
    end

    def subscription_label(subscription)
      row = current_subscription_rows(subscription).first
      row&.fetch(:label, nil) || copy("plan_title", "Plan")
    end

    def offer_summary(option)
      [catalog_offer_label(option), cadence_label(option.recurrence, option.interval)].compact.join(" · ")
    end
  end
end
