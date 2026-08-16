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

    def change_kind_label(kind)
      copy("change_kind_#{kind}", kind.to_s.humanize)
    end

    def current_terms
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

    def proposed_terms
      return cancellation_terms if cancellation? || intent&.change_kind.to_s == "cancellation"
      return resumption_terms if intent&.change_kind.to_s == "resumption"

      terms = proposal&.canonical_data || intent&.frozen_terms&.dig("proposed", "canonical_data")
      return {} unless terms

      {
        label: offer_label(
          kind: snapshot_value(terms, "product", "kind") || "plan",
          interval: snapshot_value(terms, "billing_option", "interval"),
          recurrence: snapshot_value(terms, "billing_option", "recurrence"),
          name: snapshot_value(terms, "product", "name"),
          amount_minor: snapshot_value(terms, "price", "amount_minor")
        ),
        quantity: snapshot_value(terms, "price", "quantity"),
        amount: display_amount(snapshot_value(terms, "price", "amount_minor"),
                               snapshot_value(terms, "price", "currency_code")),
        cadence: cadence_label(snapshot_value(terms, "billing_option", "recurrence"),
                               snapshot_value(terms, "billing_option", "interval"))
      }
    end

    def consequences
      if cancellation?
        [
          copy("cancel_consequence_access", "Your plan stays available until the provider confirms this request."),
          copy("cancel_consequence_usage", "New purchases and extra usage stop after the change takes effect."),
          copy("cancel_consequence_charges", "Past charges stay on your invoices. This request is not a refund.")
        ]
      else
        [
          copy("resume_consequence_access", "Your plan resumes only after the provider confirms this request."),
          copy("resume_consequence_charges", "Billing continues from the effective date.")
        ]
      end
    end

    def effective_description
      return intent.effective_at.to_fs(:long) if intent&.effective_at

      copy("change_effective_after_confirmation", "Immediately after provider confirmation")
    end

    def result_notice
      copy("change_result_notice", "The charge and tax update after the provider confirms this request.")
    end

    def page = :subscriptions

    private

    def cancellation_terms
      {
        label: copy("change_cancel_proposed", "Plan cancelled"),
        quantity: nil,
        amount: nil,
        cadence: nil
      }
    end

    def resumption_terms
      {
        label: copy("change_resume_proposed", "Plan resumed"),
        quantity: nil,
        amount: nil,
        cadence: nil
      }
    end
  end
end
