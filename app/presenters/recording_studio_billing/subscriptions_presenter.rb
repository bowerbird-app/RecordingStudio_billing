# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionsPresenter < BasePresenter
    attr_accessor :subscriptions, :eligible_options

    def page = :subscriptions

    def current_subscription_rows(subscription)
      subscription.item_versions.where(effective_ends_at: nil).order(:line_key).map do |version|
        snapshot = version.commercial_snapshot || {}
        {
          label: snapshot_value(snapshot, "product", "name") || snapshot_value(snapshot, "product", "key") || version.line_key,
          quantity: version.quantity,
          amount: display_amount(version.amount_minor, version.currency_code),
          interval: version.interval,
          benefits: display_value(snapshot_value(snapshot, "benefits")),
          overage: display_value(snapshot_value(snapshot, "overage")),
          market: display_value(snapshot_value(snapshot, "market"))
        }
      end
    end

    def offer_summary(option)
      [option.key, option.recurrence, option.interval, option.lifecycle_policy, option.proration_policy].compact.join(" | ")
    end
  end
end
