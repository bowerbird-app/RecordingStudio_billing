# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class BillingUiCustomerCopyTest < Minitest::Test
  Root = Struct.new(:id)
  Product = Struct.new(:kind, :name)
  Recording = Struct.new(:id, :recordable)
  Option = Struct.new(:key, :recurrence, :interval, :lifecycle_policy, :checkout_policy, :quantity_mode,
                      :default_quantity, :minimum_quantity, :maximum_quantity, :recording, :product_recording,
                      keyword_init: true)
  Version = Struct.new(:line_key, :mode, :quantity, :amount_minor, :currency_code, :interval, :commercial_snapshot,
                       keyword_init: true)
  Subscription = Struct.new(:identifier, :state, :currency_code, :item_versions, keyword_init: true)
  Period = Struct.new(:usage_key, :starts_at, :ends_at, :state, :usage_allowance_policies, keyword_init: true)
  Policy = Struct.new(:consumed_quantity, :limit_quantity, keyword_init: true)
  Invoice = Struct.new(:id, :total_minor, :currency_code, :state, :issued_at, keyword_init: true)
  Payment = Struct.new(:amount_minor, :currency_code, :state, :financial_command, :safe_snapshot, keyword_init: true)
  Command = Struct.new(:state)

  def test_overview_uses_plan_labels_instead_of_identifiers_and_markets
    presenter = RecordingStudioBilling::OverviewPresenter.new(
      root_recording: root, subscriptions: [subscription], checkout_intents: []
    )
    row = presenter.subscription_rows.sole

    assert_equal "Monthly plan", row[:label]
    assert_equal "Active", row[:state]
    assert_includes row[:summary], "Monthly plan"
    refute_includes row[:summary], "Market"
    refute_equal subscription.identifier, row[:label]
  end

  def test_plan_and_addon_offers_use_customer_labels
    option = offer_option(kind: "plan", interval: "month", recurrence: "recurring")
    plan_html = render_component(
      RecordingStudioBilling::SubscriptionsComponent,
      RecordingStudioBilling::SubscriptionsPresenter.new(root_recording: root, subscriptions: [], eligible_options: [option])
    )
    addon_html = render_component(
      RecordingStudioBilling::AddonsComponent,
      RecordingStudioBilling::AddonsPresenter.new(root_recording: root, purchases: [], eligible_options: [option])
    )

    assert_includes plan_html, "Monthly plan · monthly"
    assert_includes addon_html, "Monthly plan · monthly"
    refute_includes plan_html, option.key
    refute_includes addon_html, option.key
  end

  def test_usage_hides_raw_keys_and_internal_hashes
    period = Period.new(
      usage_key: "demo_api_calls", starts_at: Time.utc(2026, 8, 1), ends_at: Time.utc(2026, 8, 31),
      state: "open", usage_allowance_policies: [Policy.new(consumed_quantity: 5, limit_quantity: 10)]
    )
    html = render_component(
      RecordingStudioBilling::UsageComponent,
      RecordingStudioBilling::UsagePresenter.new(
        root_recording: root, entitlements: { "credits" => { "demo_api_calls" => 3 } },
        periods: [period], credit_grants: [], allocations: []
      )
    )

    assert_includes html, "API calls"
    assert_includes html, "5 of 10 included this period"
    refute_includes html, "demo_api_calls"
    refute_includes html, "Caps"
    refute_includes html, "Grant allocation"
  end

  def test_invoice_and_payment_copy_avoids_ids_and_snapshot_dumps
    invoice = Invoice.new(
      id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", total_minor: 1_000, currency_code: "USD",
      state: "captured", issued_at: Time.utc(2026, 8, 16)
    )
    payment = Payment.new(amount_minor: 1_000, currency_code: "USD", state: "captured",
                          financial_command: Command.new("succeeded"),
                          safe_snapshot: { "source" => "card", "tax" => { "status" => "final" } })
    payment.define_singleton_method(:[]) do |key|
      key == :safe_snapshot ? safe_snapshot : nil
    end
    invoices = RecordingStudioBilling::InvoicesPresenter.new(
      root_recording: root, invoices: [invoice], adjustments: [], refunds: []
    )
    payments = RecordingStudioBilling::PaymentsPresenter.new(
      root_recording: root, payments: [payment], refunds: [], refund_intents: []
    )

    assert_includes invoices.invoice_label(invoice), "Invoice"
    assert_includes invoices.invoice_label(invoice), "1000 USD"
    refute_includes invoices.invoice_label(invoice), invoice.id
    assert_equal "Paid by card", payments.payment_summary(payment)
  end

  private

  def root
    @root ||= Root.new("root-1")
  end

  def subscription
    version = Version.new(
      line_key: "item-1", mode: "monthly_subscription", quantity: 1, amount_minor: 4_900,
      currency_code: "USD", interval: "month",
      commercial_snapshot: { "canonical_data" => { "product" => { "kind" => "plan" },
                                                   "billing_option" => { "recurrence" => "recurring" } } }
    )
    versions = [version]
    versions.define_singleton_method(:where) { |**| versions }
    versions.define_singleton_method(:order) { |*| versions }
    Subscription.new(identifier: "sub-identifier-secret", state: "active", currency_code: "USD", item_versions: versions)
  end

  def offer_option(kind:, interval:, recurrence:)
    product = Product.new(kind, nil)
    recording = Recording.new("option-recording-1", product)
    Option.new(
      key: "demo_secret_option_key", recurrence:, interval:, lifecycle_policy: "immediate",
      checkout_policy: "allowed", quantity_mode: "fixed", default_quantity: 1,
      minimum_quantity: 1, maximum_quantity: 1, recording:, product_recording: recording
    )
  end

  def render_component(component_class, presenter)
    RecordingStudioBilling::ApplicationController.render(
      inline: "<%= render component %>",
      locals: { component: component_class.new(presenter:) }
    )
  end
end
