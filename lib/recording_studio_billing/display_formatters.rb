# frozen_string_literal: true

module RecordingStudioBilling
  # Human-readable money, dates, and admin/customer status labels for Billing UI.
  # Cents stay in the database; display divides by the currency exponent and prefixes a symbol.
  module DisplayFormatters
    CURRENCY_SYMBOLS = {
      "USD" => "$",
      "EUR" => "€",
      "GBP" => "£"
    }.freeze

    PRODUCT_KIND_LABELS = {
      "plan" => "Plan",
      "addon" => "Add-on",
      "credit_pack" => "Credit pack",
      "service" => "Service"
    }.freeze

    COMMAND_TYPE_LABELS = {
      "subscription_change" => "Plan change",
      "checkout" => "Checkout",
      "refund" => "Refund",
      "adjustment" => "Adjustment",
      "collect_usage" => "Usage charge"
    }.freeze

    ADMIN_STATE_LABELS = {
      "requires_reconciliation" => "Needs a look",
      "requires_review" => "Needs a look",
      "pending_provider" => "Waiting",
      "awaiting_confirmation" => "Waiting",
      "executing" => "Waiting",
      "pending" => "Waiting",
      "uncertain" => "Waiting",
      "processing" => "Waiting",
      "succeeded" => "Done",
      "completed" => "Done",
      "captured" => "Paid",
      "paid" => "Paid",
      "failed" => "Failed",
      "cancelled" => "Cancelled",
      "canceled" => "Cancelled",
      "active" => "Active",
      "trialing" => "Trial",
      "past_due" => "Past due",
      "paused" => "Paused",
      "draft" => "Draft",
      "open" => "Open",
      "closed" => "Closed",
      "published" => "Published",
      "retired" => "Retired",
      "scheduled" => "Scheduled",
      "applied" => "Applied"
    }.freeze

    RECONCILIATION_KIND_LABELS = {
      "provider_result_mismatch" => "Provider mismatch"
    }.freeze

    module_function

    def format_money(amount_minor, currency_code, exponent: 2)
      return if amount_minor.nil?

      code = currency_code.to_s.upcase
      exp = Integer(exponent)
      units = amount_minor.to_i / (10.0**exp)
      formatted = if units == units.to_i
                    units.to_i.to_s
                  else
                    format("%.#{exp}f", units)
                  end
      symbol = CURRENCY_SYMBOLS[code]
      return "#{symbol}#{formatted}" if symbol

      "#{formatted} #{code}"
    end

    def format_date(time, now: Time.current)
      return if time.blank?

      stamp = time.respond_to?(:in_time_zone) ? time.in_time_zone : time
      if stamp.year == now.year
        stamp.strftime("%-d %b")
      else
        stamp.strftime("%-d %b %Y")
      end
    end

    def format_usage_window(starts_at, ends_at, now: Time.current)
      return if starts_at.blank? || ends_at.blank?

      start_time = starts_at.respond_to?(:in_time_zone) ? starts_at.in_time_zone : starts_at
      end_time = ends_at.respond_to?(:in_time_zone) ? ends_at.in_time_zone : ends_at
      duration = end_time - start_time

      if hour_window?(duration)
        return "Last hour" if recent_hour_window?(start_time, end_time, now)

        return format_date(start_time, now:)
      end

      if calendar_month_window?(start_time, end_time)
        return "This month" if start_time.year == now.year && start_time.month == now.month

        return start_time.strftime("%b %Y")
      end

      return format_date(start_time, now:) if start_time.to_date == end_time.to_date

      "#{format_date(start_time, now:)} – #{format_date(end_time, now:)}"
    end

    def product_kind_label(kind)
      PRODUCT_KIND_LABELS.fetch(kind.to_s) { title_case_key(kind) }
    end

    def command_type_label(command_type)
      COMMAND_TYPE_LABELS.fetch(command_type.to_s) { title_case_key(command_type) }
    end

    def admin_state_label(state)
      ADMIN_STATE_LABELS.fetch(state.to_s) { title_case_key(state) }
    end

    def reconciliation_kind_label(kind)
      RECONCILIATION_KIND_LABELS.fetch(kind.to_s) { title_case_key(kind) }
    end

    def title_case_key(value)
      value.to_s.tr("_", " ").strip.split.map(&:capitalize).join(" ")
    end

    def customer_money_state(value)
      case value.to_s
      when "requires_review", "requires_reconciliation", "pending_provider", "awaiting_confirmation",
           "executing", "pending", "uncertain", "processing"
        "Waiting"
      when "scheduled" then "Scheduled"
      when "applied" then "Applied"
      when "completed", "succeeded", "captured", "paid" then "Succeeded"
      when "failed" then "Failed"
      when "cancelled", "canceled" then "Cancelled"
      when "trialing" then "Trial"
      when "active" then "Active"
      when "past_due" then "Past due"
      when "paused" then "Paused"
      when "open" then "Open"
      when "closed" then "Closed"
      else
        title_case_key(value)
      end
    end

    def money_state_complete?(label)
      label.to_s.in?(%w[Succeeded Applied Paid Done Closed])
    end

    def hour_window?(duration)
      duration.between?(59.minutes, 1.hour + 1.minute)
    end
    private_class_method :hour_window?

    def recent_hour_window?(start_time, end_time, now)
      start_time >= now - 2.hours && end_time <= now + 1.hour
    end
    private_class_method :recent_hour_window?

    def calendar_month_window?(start_time, end_time)
      start_time.to_date == start_time.beginning_of_month.to_date &&
        end_time.to_date >= start_time.end_of_month.to_date
    end
    private_class_method :calendar_month_window?
  end
end
