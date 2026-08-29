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

    def display_amount(amount_minor, currency_code, exponent: 2)
      DisplayFormatters.format_money(amount_minor, currency_code, exponent:)
    end

    def customer_price(amount_minor, currency_code, exponent: 2)
      display_amount(amount_minor, currency_code, exponent:)
    end

    def display_date(time)
      DisplayFormatters.format_date(time)
    end

    def display_usage_window(starts_at, ends_at)
      DisplayFormatters.format_usage_window(starts_at, ends_at)
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
      [display_date(issued), display_amount(invoice.total_minor, invoice.currency_code)].compact.join(" · ")
    end

    def current_subscription_lines(subscription)
      lines = subscription.active_lines.order(:line_key).to_a
      lines.sort_by { |line| plan_line?(line) ? 0 : 1 }
    end

    def plan_line?(line)
      snapshot_value(canonical_terms(line.commercial_snapshot), "product", "kind").to_s == "plan"
    end

    def money_state(value)
      DisplayFormatters.customer_money_state(value)
    end

    def money_state_complete?(state)
      DisplayFormatters.money_state_complete?(money_state(state))
    end

    def show_money_status?(state)
      !money_state_complete?(state)
    end

    private

    def human_usage_key(key)
      stripped = key.delete_prefix("demo_")
      return copy("usage_api_calls", "API calls") if stripped.match?(/api.?calls/i)

      stripped.tr("_", " ").capitalize
    end
  end
end
