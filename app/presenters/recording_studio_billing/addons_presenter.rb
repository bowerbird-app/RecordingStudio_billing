# frozen_string_literal: true

module RecordingStudioBilling
  class AddonsPresenter < BasePresenter
    attr_accessor :purchases, :eligible_options

    def page = :addons

    def purchase_rows
      purchases.map do |purchase|
        snapshot = purchase.commercial_snapshot || {}
        {
          mode: purchase.mode.humanize, quantity: purchase.quantity,
          amount: display_amount(purchase.amount_minor, purchase.currency_code),
          benefits: display_value(snapshot_value(snapshot, "benefits")),
          grant: purchase.effects.map { |effect| display_value(effect.safe_metadata) }.reject(&:blank?).join("; "),
          expiry: purchase.effects.map(&:effective_at).compact.max&.to_fs(:long),
          refund: display_value(snapshot_value(snapshot, "refund_policy") || snapshot_value(snapshot, "refund"))
        }
      end
    end

    def offer_summary(option)
      [option.key, option.recurrence, option.lifecycle_policy, option.checkout_policy].compact.join(" | ")
    end
  end
end
