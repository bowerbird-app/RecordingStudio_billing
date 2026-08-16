# frozen_string_literal: true

module RecordingStudioBilling
  class AddonsPresenter < BasePresenter
    attr_accessor :purchases, :eligible_options

    def page = :addons

    def purchase_rows
      purchases.map do |purchase|
        terms = canonical_terms(purchase.commercial_snapshot)
        {
          label: offer_label(
            kind: snapshot_value(terms, "product", "kind") || "addon",
            interval: snapshot_value(terms, "billing_option", "interval"),
            recurrence: snapshot_value(terms, "billing_option", "recurrence") || purchase.mode,
            name: snapshot_value(terms, "product", "name"),
            amount_minor: purchase.amount_minor
          ),
          quantity: purchase.quantity,
          amount: display_amount(purchase.amount_minor, purchase.currency_code),
          cadence: cadence_label(snapshot_value(terms, "billing_option", "recurrence"),
                                 snapshot_value(terms, "billing_option", "interval")),
          expiry: purchase.effects.map(&:effective_at).compact.max&.to_fs(:long)
        }
      end
    end

    def offer_summary(option)
      [catalog_offer_label(option), cadence_label(option.recurrence, option.interval)].compact.join(" · ")
    end
  end
end
