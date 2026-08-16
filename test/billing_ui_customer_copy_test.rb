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
  Subscription = Struct.new(:id, :identifier, :state, :currency_code, :item_versions, keyword_init: true)
  Period = Struct.new(:usage_key, :starts_at, :ends_at, :state, :usage_allowance_policies, keyword_init: true)
  Policy = Struct.new(:consumed_quantity, :limit_quantity, keyword_init: true)
  Invoice = Struct.new(:id, :total_minor, :currency_code, :state, :issued_at, keyword_init: true)
  Payment = Struct.new(:amount_minor, :currency_code, :state, :financial_command, :safe_snapshot, keyword_init: true)
  Command = Struct.new(:state)
  RefundIntent = Struct.new(:amount_minor, :currency_code, :state, :financial_command, :refund, keyword_init: true)

  def test_overview_uses_plan_labels_instead_of_identifiers_and_markets
    presenter = RecordingStudioBilling::OverviewPresenter.new(
      root_recording: root, subscriptions: [subscription], checkout_intents: []
    )
    row = presenter.subscription_rows.sole

    assert_equal "Monthly plan", row[:label]
    assert_equal "Active", row[:state]
    assert_equal "$49", row[:price_label]
    assert_equal "/mo", row[:price_suffix]
    assert_includes row[:summary], "Monthly plan"
    assert_includes row[:summary], "Add-on"
    refute_includes row[:summary], "Market"
    refute_equal subscription.identifier, row[:label]

    html = render_component(RecordingStudioBilling::BillingOverviewComponent, presenter)
    assert_includes html, "$49"
    assert_includes html, "View plans"
    assert_includes html, "Billed monthly"
    refute_includes html, "Add-on: 2 x"
    refute_includes html, "Choose a plan"
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

    assert_includes plan_html, "Monthly plan"
    assert_includes plan_html, "Choose a plan"
    assert_includes plan_html, "Pick the plan that fits this workspace"
    assert_includes plan_html, "text-3xl font-bold"
    refute_includes plan_html, "Cancel plan"
    refute_includes plan_html, "Plan requests"
    refute_includes plan_html, "Scheduled"
    assert_includes addon_html, "Monthly plan · monthly"
    refute_includes plan_html, option.key
    refute_includes addon_html, option.key
    refute_includes plan_html, "Usage ·"
  end

  def test_plan_page_shows_three_priced_cards_in_cadence_order
    free = offer_option(kind: "plan", interval: "month", recurrence: "recurring", key: "free_option")
    monthly = offer_option(kind: "plan", interval: "month", recurrence: "recurring", key: "monthly_option")
    annual = offer_option(kind: "plan", interval: "year", recurrence: "recurring", key: "annual_option")
    presenter = RecordingStudioBilling::SubscriptionsPresenter.new(
      root_recording: root, subscriptions: [], eligible_options: [annual, monthly, free]
    )
    amounts = { free => 0, monthly => 4_900, annual => 49_000 }
    presenter.define_singleton_method(:live_price_for) do |option|
      Struct.new(:amount_minor, :currency_code, :currency_exponent).new(amounts.fetch(option), "USD", 2)
    end
    cards = presenter.plan_cards
    html = render_component(RecordingStudioBilling::SubscriptionsComponent, presenter)

    assert_equal(["Free plan", "Monthly plan", "Annual plan"], cards.map { |card| card[:name] })
    assert_equal(["$0", "$49", "$490"], cards.map { |card| card[:price_label] })
    assert_equal(["/mo", "/mo", "/yr"], cards.map { |card| card[:price_suffix] })
    assert_includes html, "Choose this plan"
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
    assert_equal "Succeeded", payments.payment_state(payment)
  end

  def test_cancel_confirmation_lists_consequences_and_an_effective_date
    html = render_component(
      RecordingStudioBilling::SubscriptionChangeComponent,
      RecordingStudioBilling::SubscriptionChangePresenter.new(
        root_recording: root, subscription:, change_kind: :cancellation
      )
    )

    assert_includes html, "Cancel plan"
    assert_includes html, "Past charges stay on your invoices"
    assert_includes html, "Effective"
    refute_includes html, "recordable"
  end

  def test_pending_refunds_use_waiting_copy
    intent = RefundIntent.new(amount_minor: 50, currency_code: "USD", state: "requires_review",
                              financial_command: Command.new("requires_reconciliation"), refund: nil)
    payments = RecordingStudioBilling::PaymentsPresenter.new(
      root_recording: root, payments: [], refunds: [], refund_intents: [intent]
    )

    assert_equal "Waiting for confirmation", payments.pending_refund_rows.sole.fetch(:status)
  end

  private

  def root
    @root ||= Root.new("root-1")
  end

  def subscription
    addon = Version.new(
      line_key: "addon-1", mode: "recurring_addon", quantity: 2, amount_minor: 1_000,
      currency_code: "USD", interval: "month",
      commercial_snapshot: { "canonical_data" => { "product" => { "kind" => "addon" },
                                                   "billing_option" => { "recurrence" => "recurring" } } }
    )
    version = Version.new(
      line_key: "item-1", mode: "monthly_subscription", quantity: 1, amount_minor: 4_900,
      currency_code: "USD", interval: "month",
      commercial_snapshot: { "canonical_data" => { "product" => { "kind" => "plan" },
                                                   "billing_option" => { "recurrence" => "recurring" } } }
    )
    versions = [addon, version]
    versions.define_singleton_method(:where) { |**| versions }
    versions.define_singleton_method(:order) { |*| versions }
    Subscription.new(id: "sub-1", identifier: "sub-identifier-secret", state: "active", currency_code: "USD", item_versions: versions)
  end

  def offer_option(kind:, interval:, recurrence:, key: "demo_secret_option_key")
    product = Product.new(kind, nil)
    recording = Recording.new("option-recording-1", product)
    Option.new(
      key:, recurrence:, interval:, lifecycle_policy: "immediate",
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
