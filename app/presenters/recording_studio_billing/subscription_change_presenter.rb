# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionChangePresenter < BasePresenter
    attr_accessor :subscription, :change_kind, :intent, :eligible_options, :proposal, :request_key

    def cancellation? = change_kind == :cancellation

    def result? = intent.present?

    def selection? = change_kind == :selection

    def change_kinds_for(option)
      product_kind = option.product_recording.recordable.kind
      kinds = if product_kind == "plan"
                %w[plan interval]
              else
                (product_kind == "addon" ? ["addon"] : [])
              end
      if option.quantity_mode == "adjustable" && subscription.item_versions.where(effective_ends_at: nil)
                                                             .exists?(billing_option_recording_id: option.recording.id)
        kinds << "quantity"
      end
      kinds
    end

    def current_terms
      subscription.item_versions.where(effective_ends_at: nil).order(:line_key).map do |version|
        { line_key: version.line_key, quantity: version.quantity, amount_minor: version.amount_minor,
          currency_code: version.currency_code, interval: version.interval, manifest_digest: version.manifest_digest }
      end
    end

    def proposed_terms
      terms = proposal&.canonical_data || intent&.frozen_terms&.dig("proposed", "canonical_data")
      return {} unless terms

      { quantity: terms.dig("price", "quantity"), amount_minor: terms.dig("price", "amount_minor"),
        currency_code: terms.dig("price", "currency_code"), interval: terms.dig("billing_option", "interval"),
        manifest_digest: proposal&.manifest_digest || intent&.proposed_manifest_digest }
    end

    def effective_description
      return intent.effective_at.to_fs(:long) if intent&.effective_at

      "Immediately after provider confirmation"
    end

    def expected_effects
      intent&.outcome || { "financial_effect" => { "authority" => "provider_pending" },
                           "tax_effect" => { "authority" => "provider_pending" } }
    end

    def page = :subscriptions
  end
end
