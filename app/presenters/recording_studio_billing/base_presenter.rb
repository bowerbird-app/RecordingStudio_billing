# frozen_string_literal: true

module RecordingStudioBilling
  class BasePresenter
    attr_reader :root_recording

    def initialize(root_recording:, **attributes)
      @root_recording = root_recording
      attributes.each { |name, value| public_send("#{name}=", value) }
    end

    def copy(key, default)
      RecordingStudioBilling.configuration.billing_copy.fetch(key.to_s, default)
    end

    def support_url
      RecordingStudioBilling.configuration.support_url
    end

    def navigation_items
      RecordingStudioBilling.configuration.hooks.billing_navigation_items(self)
    end

    def page_contents(page)
      RecordingStudioBilling.configuration.hooks.billing_page_contents(page, self)
    end

    def display_amount(amount_minor, currency_code)
      [amount_minor, currency_code].compact.join(" ")
    end

    def customer_price(amount_minor, currency_code, exponent: 2)
      units = amount_minor.to_i / (10.0**exponent)
      formatted = units == units.to_i ? units.to_i.to_s : format("%.#{exponent}f", units)
      case currency_code.to_s.upcase
      when "USD" then "$#{formatted}"
      when "EUR" then "€#{formatted}"
      when "GBP" then "£#{formatted}"
      else
        "#{formatted} #{currency_code}"
      end
    end

    def price_interval_suffix(interval)
      case interval.to_s
      when "year" then copy("price_suffix_year", "/yr")
      when "week" then copy("price_suffix_week", "/wk")
      else copy("price_suffix_month", "/mo")
      end
    end

    def display_value(value)
      case value
      when Hash
        value.map { |key, nested_value| "#{key.to_s.humanize}: #{display_value(nested_value)}" }.join(", ")
      when Array
        value.map { |nested_value| display_value(nested_value) }.join(", ")
      when nil
        nil
      else
        value.to_s
      end
    end

    def snapshot_value(snapshot, *keys)
      keys.reduce(snapshot || {}) { |value, key| value.is_a?(Hash) ? value[key.to_s] || value[key.to_sym] : nil }
    end

    def canonical_terms(snapshot)
      return {} unless snapshot.is_a?(Hash)

      nested = snapshot_value(snapshot, "canonical_data")
      nested.is_a?(Hash) ? nested : snapshot
    end

    def offer_label(kind:, interval: nil, name: nil, amount_minor: nil, key: nil, **)
      resolved_name = name.presence || product_display_name(key)
      return resolved_name if resolved_name.present?

      case kind.to_s
      when "addon"
        copy("offer_addon", "Add-on")
      when "credit_pack"
        copy("offer_credit_pack", "Credit pack")
      when "service"
        copy("offer_usage", "Usage")
      when "plan"
        return copy("offer_free_plan", "Free plan") if amount_minor&.zero?

        case interval.to_s
        when "year" then copy("offer_annual_plan", "Annual plan")
        when "week" then copy("offer_weekly_plan", "Weekly plan")
        else copy("offer_monthly_plan", "Monthly plan")
        end
      else
        copy("offer_plan", "Plan")
      end
    end

    def catalog_offer_label(option)
      product = option.product_recording.recordable
      offer_label(kind: product.kind, interval: option.interval, recurrence: option.recurrence,
                  name: product.try(:name), key: product.try(:key))
    end

    def product_display_name(key)
      return if key.blank?

      RecordingStudioBilling.configuration.product_display_names[key.to_s].presence
    end

    def cadence_label(recurrence, interval = nil)
      return copy("checkout_cadence_one_time", "one-time") unless recurrence.to_s == "recurring"

      case interval.to_s
      when "year" then copy("checkout_cadence_yearly", "yearly")
      when "week" then copy("checkout_cadence_weekly", "weekly")
      else copy("checkout_cadence_monthly", "monthly")
      end
    end

    def usage_label(key)
      normalized = key.to_s
      copy("usage_#{normalized}", human_usage_key(normalized))
    end

    def invoice_label(invoice)
      issued = invoice.issued_at || invoice.try(:created_at)
      [copy("invoice_title", "Invoice"), issued&.to_fs(:long),
       display_amount(invoice.total_minor, invoice.currency_code)].compact.join(" · ")
    end

    def current_subscription_lines(subscription)
      lines = subscription.active_lines.order(:line_key).to_a
      lines.sort_by { |line| plan_line?(line) ? 0 : 1 }
    end

    def plan_line?(line)
      snapshot_value(canonical_terms(line.commercial_snapshot), "product", "kind").to_s == "plan"
    end

    def money_state(value)
      case value.to_s
      when "requires_review", "requires_reconciliation", "pending_provider", "awaiting_confirmation",
           "executing", "pending", "uncertain", "processing"
        copy("money_state_waiting", "Waiting for confirmation")
      when "scheduled" then copy("money_state_scheduled", "Scheduled")
      when "applied" then copy("money_state_applied", "Applied")
      when "completed", "succeeded", "captured", "paid" then copy("money_state_complete", "Succeeded")
      when "failed" then copy("money_state_failed", "Failed")
      when "cancelled", "canceled" then copy("money_state_cancelled", "Cancelled")
      when "trialing" then copy("money_state_trialing", "Trial")
      when "active" then copy("money_state_active", "Active")
      when "past_due" then copy("money_state_past_due", "Past due")
      when "paused" then copy("money_state_paused", "Paused")
      else
        value.to_s.humanize
      end
    end

    private

    def human_usage_key(key)
      stripped = key.delete_prefix("demo_")
      return copy("usage_api_calls", "API calls") if stripped.match?(/api.?calls/i)
      return copy("usage_ai_credits", "AI credits") if stripped.match?(/ai.?credits/i)

      stripped.tr("_", " ").capitalize
    end
  end
end
