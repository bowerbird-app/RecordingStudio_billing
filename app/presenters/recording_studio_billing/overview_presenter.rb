# frozen_string_literal: true

module RecordingStudioBilling
  class OverviewPresenter < BasePresenter
    attr_accessor :subscriptions, :checkout_intents

    def page = :overview

    def subscription_rows
      subscriptions.map do |subscription|
        versions = subscription.item_versions.where(effective_ends_at: nil).order(:line_key)
        { identifier: subscription.identifier, state: subscription.state.humanize, currency: subscription.currency_code,
          lifecycle: versions.map { |version| "#{version.mode.humanize}: #{version.quantity} x #{display_amount(version.amount_minor, version.currency_code)} #{version.interval}" }.join("; "),
          benefits: versions.map { |version| display_value(snapshot_value(version.commercial_snapshot, "benefits")) }.reject(&:blank?).join("; "),
          market: versions.map { |version| display_value(snapshot_value(version.commercial_snapshot, "market")) }.reject(&:blank?).join("; ") }
      end
    end
  end
end
