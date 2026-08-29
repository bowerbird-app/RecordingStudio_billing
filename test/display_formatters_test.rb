# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class DisplayFormattersTest < ActiveSupport::TestCase
  test "money uses currency symbols and divides minor units" do
    assert_equal "$49", RecordingStudioBilling::DisplayFormatters.format_money(4_900, "USD")
    assert_equal "$49.50", RecordingStudioBilling::DisplayFormatters.format_money(4_950, "USD")
    assert_equal "$1", RecordingStudioBilling::DisplayFormatters.format_money(100, "USD")
    assert_equal "€470", RecordingStudioBilling::DisplayFormatters.format_money(47_000, "EUR")
    assert_equal "£39", RecordingStudioBilling::DisplayFormatters.format_money(3_900, "GBP")
  end

  test "dates omit the year in the current year" do
    now = Time.utc(2026, 8, 29)
    assert_equal "26 Aug", RecordingStudioBilling::DisplayFormatters.format_date(Time.utc(2026, 8, 26), now:)
    assert_equal "26 Aug 2025", RecordingStudioBilling::DisplayFormatters.format_date(Time.utc(2025, 8, 26), now:)
  end

  test "usage windows prefer last hour this month and short dates" do
    now = Time.utc(2026, 8, 29, 7, 30)
    assert_equal "Last hour",
                 RecordingStudioBilling::DisplayFormatters.format_usage_window(
                   Time.utc(2026, 8, 29, 6), Time.utc(2026, 8, 29, 7), now:
                 )
    assert_equal "26 Aug",
                 RecordingStudioBilling::DisplayFormatters.format_usage_window(
                   Time.utc(2026, 8, 26, 3), Time.utc(2026, 8, 26, 4), now:
                 )
    assert_equal "This month",
                 RecordingStudioBilling::DisplayFormatters.format_usage_window(
                   Time.utc(2026, 8, 1), Time.utc(2026, 8, 31).end_of_day, now:
                 )
  end

  test "admin labels prefer human command and state copy" do
    assert_equal "Plan", RecordingStudioBilling::DisplayFormatters.product_kind_label("plan")
    assert_equal "Credit pack", RecordingStudioBilling::DisplayFormatters.product_kind_label("credit_pack")
    assert_equal "Plan change", RecordingStudioBilling::DisplayFormatters.command_type_label("subscription_change")
    assert_equal "Needs a look", RecordingStudioBilling::DisplayFormatters.admin_state_label("requires_reconciliation")
    assert_equal "Done", RecordingStudioBilling::DisplayFormatters.admin_state_label("succeeded")
    assert_equal "Paid", RecordingStudioBilling::DisplayFormatters.admin_state_label("captured")
    assert_equal "Provider mismatch",
                 RecordingStudioBilling::DisplayFormatters.reconciliation_kind_label("provider_result_mismatch")
    assert_equal "Waiting", RecordingStudioBilling::DisplayFormatters.customer_money_state("requires_reconciliation")
  end
end
