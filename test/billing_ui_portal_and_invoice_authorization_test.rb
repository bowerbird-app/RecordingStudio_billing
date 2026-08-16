# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require "rails/test_help"
require "devise/test/integration_helpers"

class BillingUiPortalAndInvoiceAuthorizationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    BillingTestDatabaseCleanup.clear!
    RecordingStudioBilling.configuration.reset_registries!
    @portal_context_resolver = RecordingStudioBilling.configuration.billing_portal_context_resolver
    Current.actor = nil
    @user = User.create!(email: "billing-boundary-#{SecureRandom.hex(4)}@example.test", password: "Password1!",
                         password_confirmation: "Password1!")
    @unauthorized_user = User.create!(email: "billing-denied-#{SecureRandom.hex(4)}@example.test", password: "Password1!",
                                      password_confirmation: "Password1!")
    @root = customer_root("Customer")
    @other_root = customer_root("Other customer")
    sign_in @user
    select_root(@root)
    Current.actor = @user
    @account = account_for(@root, "Customer")
    @other_account = account_for(@other_root, "Other customer")
  end

  teardown do
    Current.actor = nil
    RecordingStudioBilling.configuration.billing_portal_context_resolver = @portal_context_resolver
    BillingTestDatabaseCleanup.clear!
  end

  test "invoice routes do not disclose another root's invoices" do
    invoice = invoice_for(root: @other_root, account: @other_account)

    with_authorization(true) { get "/billing/invoices/#{invoice.id}" }

    assert_response :not_found
  end

  test "ungranted users cannot view or download invoices" do
    invoice = invoice_for(root: @root, account: @account)
    sign_in @unauthorized_user
    select_root(@root, actor: @unauthorized_user)

    with_authorization(false) { get "/billing/invoices/#{invoice.id}" }
    assert_response :not_found

    with_authorization(false) { get "/billing/invoices/#{invoice.id}/download" }
    assert_response :not_found
  end

  test "authorized invoice download streams a PDF privately" do
    invoice = invoice_for(root: @root, account: @account, adapter_key: "invoice_pdf")
    RecordingStudioBilling.register_provider("invoice_pdf", InvoiceAdapter.new(trusted_download("%PDF-1.7")))

    with_authorization(true) { get "/billing/invoices/#{invoice.id}/download" }

    assert_response :success
    assert_equal "private, no-store", response.headers.fetch("Cache-Control")
    assert_equal "application/pdf", response.media_type
    assert_includes response.headers.fetch("Content-Disposition"), "attachment"
    assert_equal "%PDF-1.7", response.body
  end

  test "invoice and payment routes render scoped financial detail without exposing another root" do
    invoice = invoice_for(root: @root, account: @account)
    RecordingStudioBilling::InvoiceLine.create!(invoice:, description: "Overage minutes", quantity: 2,
                                                amount_minor: 500, currency_code: "USD",
                                                safe_snapshot: { "tax" => { "status" => "final" }, "overage" => true })
    command = invoice.financial_command
    RecordingStudioBilling::Payment.create!(root_recording: @root, account_recording: @account.recording,
                                            financial_command: command, currency_code: "USD", amount_minor: 1_000,
                                            state: "captured", safe_snapshot: { "source" => "card", "tax" => "final" },
                                            recorded_at: Time.current)
    other_invoice = invoice_for(root: @other_root, account: @other_account)

    with_authorization(true) { get "/billing/billing/invoices", params: { root_recording_id: @root.id } }
    assert_response :success
    assert_includes response.body, invoice.id
    refute_includes response.body, other_invoice.id

    with_authorization(true) { get "/billing/invoices/#{invoice.id}", params: { root_recording_id: @root.id } }
    assert_response :success
    assert_includes response.body, "Overage minutes"
    refute_includes response.body, "Tax/Overage"

    with_authorization(true) { get "/billing/billing/payments", params: { root_recording_id: @root.id } }
    assert_response :success
    assert_includes response.body, "1000 USD"
    assert_includes response.body, command.state.humanize
    assert_includes response.body, "Paid by card"
    refute_includes response.body, "Source, reason and tax"
  end

  test "invoice index renders scoped refund adjustment and command states" do
    invoice = invoice_for(root: @root, account: @account)
    refund_command = financial_command_for(root: @root, account: @account, type: "refund")
    refund_intent = RecordingStudioBilling::RefundIntent.create!(
      payment: RecordingStudioBilling::Payment.create!(root_recording: @root, account_recording: @account.recording,
                                                       financial_command: invoice.financial_command, currency_code: "USD",
                                                       amount_minor: 1_000, state: "paid", safe_snapshot: {}, recorded_at: Time.current),
      root_recording: @root, account_recording: @account.recording, financial_command: refund_command,
      local_idempotency_key: SecureRandom.uuid, request_fingerprint: "a" * 64, state: "completed",
      amount_minor: 200, currency_code: "USD", safe_metadata: {}
    )
    RecordingStudioBilling::Refund.create!(refund_intent:, payment: refund_intent.payment, financial_command: refund_command,
                                           amount_minor: 200, currency_code: "USD", recorded_at: Time.current, safe_snapshot: {})
    adjustment_command = financial_command_for(root: @root, account: @account, type: "adjustment")
    adjustment_intent = RecordingStudioBilling::AdjustmentIntent.create!(
      invoice:, root_recording: @root, account_recording: @account.recording, financial_command: adjustment_command,
      local_idempotency_key: SecureRandom.uuid, request_fingerprint: "b" * 64, state: "completed", kind: "credit",
      amount_minor: 100, currency_code: "USD", safe_metadata: {}
    )
    RecordingStudioBilling::FinancialAdjustment.create!(adjustment_intent:, invoice:, financial_command: adjustment_command,
                                                        kind: "credit", amount_minor: 100, currency_code: "USD",
                                                        recorded_at: Time.current, safe_snapshot: {})

    with_authorization(true) { get "/billing/billing/invoices", params: { root_recording_id: @root.id } }

    assert_response :success
    assert_includes response.body, "Credit: 100 USD"
    assert_includes response.body, "Refund: 200 USD"
    assert_includes response.body, refund_command.state.humanize
  end

  test "usage route renders only the selected root's periods grants and included amounts" do
    period = RecordingStudioBilling::UsagePeriod.create!(
      root_recording: @root, account_recording: @account.recording, usage_key: "studio_minutes",
      starts_at: 1.day.ago, ends_at: 1.day.from_now, state: "open", safe_metadata: { "tax_status" => "estimated" }
    )
    RecordingStudioBilling::UsageCreditGrant.create!(
      root_recording: @root, account_recording: @account.recording, credit_key: "studio_minutes", quantity: 100,
      remaining_quantity: 75, effective_at: 1.day.ago, expires_at: 1.month.from_now,
      source_key: "usage-ui-#{SecureRandom.uuid}", safe_metadata: { "source" => "credit_pack" }
    )
    RecordingStudioBilling::UsageAllowancePolicy.create!(
      root_recording: @root, account_recording: @account.recording, usage_period: period, usage_key: "studio_minutes",
      policy_kind: "hard_limit", limit_quantity: 100, consumed_quantity: 25, effective_at: 1.day.ago, safe_metadata: {}
    )
    hidden_period = RecordingStudioBilling::UsagePeriod.create!(
      root_recording: @other_root, account_recording: @other_account.recording, usage_key: "other_minutes",
      starts_at: 1.day.ago, ends_at: 1.day.from_now, state: "open", safe_metadata: {}
    )

    with_authorization(true) { get "/billing/billing/usage", params: { root_recording_id: @root.id } }

    assert_response :success
    assert_includes response.body, "Studio minutes"
    assert_includes response.body, "75 available of 100"
    assert_includes response.body, "25 of 100 included this period"
    refute_includes response.body, "studio_minutes"
    refute_includes response.body, "Caps"
    refute_includes response.body, "tax_status"
    refute_includes response.body, hidden_period.usage_key
  end

  test "invoice download rejects provider redirect-like payloads" do
    invoice = invoice_for(root: @root, account: @account, adapter_key: "unsafe_invoice")
    RecordingStudioBilling.register_provider("unsafe_invoice", InvoiceAdapter.new(["https://evil.example/invoice.pdf"]))

    with_authorization(true) { get "/billing/invoices/#{invoice.id}/download" }

    assert_response :not_found
  end

  test "portal uses resolver context only and supplies a server-generated return URL" do
    resolver_calls = []
    adapter_calls = []
    RecordingStudioBilling.configuration.billing_portal_context_resolver = lambda do |root_recording:, account_recording:, subscriptions:|
      resolver_calls << { root_recording:, account_recording:, subscriptions: }
      { adapter_key: "portal", customer_reference: "cus_server", options: { configuration_id: "bpc_server" } }
    end
    RecordingStudioBilling.register_provider("portal", PortalAdapter.new(url: "https://billing.stripe.com/session/test", calls: adapter_calls,
                                                                         origins: ["https://billing.stripe.com"]))

    with_authorization(true) do
      post "/billing/billing/portal", params: { customer_reference: "cus_forged", adapter_key: "forged", return_url: "https://evil.example" }
    end

    assert_redirected_to "https://billing.stripe.com/session/test"
    assert_equal @root, resolver_calls.sole.fetch(:root_recording)
    assert_equal @account.recording, resolver_calls.sole.fetch(:account_recording)
    assert_equal "cus_server", adapter_calls.sole.fetch(:customer_reference)
    assert_equal "bpc_server", adapter_calls.sole.fetch(:configuration_id)
    assert_equal "http://www.example.com/billing/billing/settings", adapter_calls.sole.fetch(:return_url)
  end

  test "Stripe portal URLs are accepted separately from trusted host return URLs" do
    calls = []
    adapter = RecordingStudioBilling::StripeAdapter.new(trusted_origins_resolver: -> { ["https://app.example.test"] })
    adapter.define_singleton_method(:portal_session) do |**attributes|
      calls << attributes
      { url: "https://billing.stripe.com/session/test" }
    end
    RecordingStudioBilling.configuration.billing_portal_context_resolver = lambda { |**|
      { adapter_key: "stripe_portal", customer_reference: "cus_server" }
    }
    RecordingStudioBilling.register_provider("stripe_portal", adapter)

    with_authorization(true) { post "/billing/billing/portal" }

    assert_redirected_to "https://billing.stripe.com/session/test"
    assert_equal "http://www.example.com/billing/billing/settings", calls.sole.fetch(:return_url)
  end

  test "ungranted users cannot create portals or invoke portal dependencies" do
    resolver_calls = []
    adapter_calls = []
    RecordingStudioBilling.configuration.billing_portal_context_resolver = lambda do |**|
      resolver_calls << true
      { adapter_key: "portal", customer_reference: "cus_server" }
    end
    RecordingStudioBilling.register_provider("portal", PortalAdapter.new(url: "https://billing.stripe.com/session/test", calls: adapter_calls,
                                                                         origins: ["https://billing.stripe.com"]))
    sign_in @unauthorized_user
    select_root(@root, actor: @unauthorized_user)

    with_authorization(false) { post "/billing/billing/portal" }

    assert_response :not_found
    assert_empty resolver_calls
    assert_empty adapter_calls
  end

  test "portal rejects malformed insecure and unapproved adapter URLs" do
    ["http://billing.stripe.com/session/test", "https://app.example.test/session/test",
     "https://evil.example/session/test", "not a URL"].each_with_index do |url, index|
      adapter_key = "portal_#{index}"
      RecordingStudioBilling.configuration.billing_portal_context_resolver = lambda { |**|
        { adapter_key:, customer_reference: "cus_server" }
      }
      RecordingStudioBilling.register_provider(adapter_key, PortalAdapter.new(url:, calls: [], origins: ["https://billing.stripe.com"]))

      with_authorization(true) { post "/billing/billing/portal" }

      assert_response :not_found, url
    end
  end

  test "portal rejects nil and non-hash provider responses" do
    [nil, "https://billing.stripe.com/session/test"].each_with_index do |response, index|
      adapter_key = "portal_response_#{index}"
      RecordingStudioBilling.configuration.billing_portal_context_resolver = lambda { |**|
        { adapter_key:, customer_reference: "cus_server" }
      }
      RecordingStudioBilling.register_provider(adapter_key, RawPortalAdapter.new(response))

      with_authorization(true) { post "/billing/billing/portal" }

      assert_response :not_found, response.inspect
    end
  end

  private

  InvoiceAdapter = Struct.new(:payload) do
    def capabilities
      RecordingStudioBilling::ProviderCapabilities.new(operations: ["invoice_download"])
    end

    def call(**)
      raise NotImplementedError
    end

    def invoice_download(**)
      payload
    end
  end

  PortalAdapter = Struct.new(:url, :calls, :origins) do
    def capabilities
      RecordingStudioBilling::ProviderCapabilities.new(operations: ["portal"])
    end

    def call(**)
      raise NotImplementedError
    end

    def trusted_portal_origins
      origins
    end

    def portal_session(**attributes)
      calls << attributes
      { url: }
    end
  end

  RawPortalAdapter = Struct.new(:response) do
    def capabilities
      RecordingStudioBilling::ProviderCapabilities.new(operations: ["portal"])
    end

    def call(**)
      raise NotImplementedError
    end

    def trusted_portal_origins
      ["https://billing.stripe.com"]
    end

    def portal_session(**)
      response
    end
  end

  def trusted_download(contents)
    RecordingStudioBilling::StripeAdapter::TrustedInvoiceDownload.new("https://files.stripe.com/invoice.pdf").tap do |download|
      download.define_singleton_method(:each) do |&block|
        return enum_for(__method__) unless block

        block.call(contents)
      end
    end
  end

  def customer_root(name)
    RecordingStudio.root_recording_for(Workspace.create!(name: "#{name} #{SecureRandom.hex(4)}"))
  end

  def account_for(root, name)
    root = RecordingStudio::Recording.unscoped.find(root.id)
    root.association(:root_recording).target = root
    account = RecordingStudioBilling::Account.new(root_recording: root, name: name)
    RecordingStudio.record!(action: "created", recordable: account, root_recording: root, parent_recording: root)
    account
  end

  def invoice_for(root:, account:, adapter_key: "fake")
    command = RecordingStudioBilling.create_financial_command(
      root_recording: root, account_recording: account.recording, command_type: "invoice_download",
      local_idempotency_key: SecureRandom.uuid, provider_account_recording: provider_recording(adapter_key),
      provider_adapter_key: adapter_key, request: { invoice: "download" }
    ).command
    RecordingStudioBilling::Invoice.create!(root_recording: root, account_recording: account.recording, financial_command: command,
                                            currency_code: "USD", total_minor: 1_000, state: "paid", issued_at: Time.current,
                                            safe_snapshot: {})
  end

  def financial_command_for(root:, account:, type:)
    RecordingStudioBilling.create_financial_command(
      root_recording: root, account_recording: account.recording, command_type: type,
      local_idempotency_key: SecureRandom.uuid, provider_account_recording: provider_recording("#{type}_provider"),
      provider_adapter_key: "#{type}_provider", request: { amount_minor: 100 }
    ).command
  end

  def provider_recording(adapter_key)
    @provider_recordings ||= {}
    @provider_recordings[adapter_key] ||= begin
      root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
      admin = RecordingStudioBilling.ensure_billing_admin(root_recording: root, key: "billing")
      RecordingStudio::Recording.unscoped.find(
        RecordingStudio.record!(action: "created", recordable: RecordingStudioBilling::ProviderAccount.new(
          billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}", adapter_key:, name: "Fake",
          environment: "test", configuration: {}, capabilities: [], supported_markets: ["US"], supported_currencies: ["USD"]
        ), root_recording: root, parent_recording: admin.recording).recording.id
      )
    end
  end

  def select_root(root, actor: @user)
    get "/"
    assert_response :success
    root.association(:root_recording).target = root
    device_key = cookies[RecordingStudioRootSwitchable.configuration.device_key_cookie_name]
    RecordingStudio::RootSwitchable::Selection.upsert_for(
      actor:, device_key:,
      scope_key: "all_workspaces", root_recording: root
    )
  end

  def with_authorization(allowed, &)
    RecordingStudioAccessible.stub(:authorized?, allowed, &)
  end
end
