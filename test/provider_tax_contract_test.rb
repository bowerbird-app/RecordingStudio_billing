# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require "rails/test_help"

class ProviderTaxContractTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class BlockingTaxCalculator < RecordingStudioBilling::FakeTaxCalculator
    attr_reader :entered_calls

    def initialize(entered:, release:, **)
      super(**)
      @entered = entered
      @release = release
      @entered_calls = 0
    end

    def call(**attributes)
      @entered_calls += 1
      @entered << true
      @release.pop
      super
    end
  end

  setup do
    clear_data!
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.configuration.tax_policy = { enabled: false }
  end

  teardown do
    clear_data!
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.configuration.tax_policy = { enabled: false }
  end

  test "registries enforce stable unique keys and reset without enabling tax" do
    provider = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success)
    calculator = RecordingStudioBilling::FakeTaxCalculator.new(outcome: :exclusive)

    assert_same provider, RecordingStudioBilling.register_provider(:fake, provider)
    assert_same calculator, RecordingStudioBilling.register_tax_calculator(:external_tax, calculator)
    assert_same provider, RecordingStudioBilling.provider_adapter("fake")
    assert_same calculator, RecordingStudioBilling.tax_calculator("external_tax")
    assert_raises(ArgumentError) { RecordingStudioBilling.register_provider(:fake, provider) }
    assert_raises(ArgumentError) { RecordingStudioBilling.register_tax_calculator(:external_tax, calculator) }
    assert_raises(ArgumentError) { RecordingStudioBilling.provider_adapter(:unknown) }
    assert_raises(ArgumentError) { RecordingStudioBilling.tax_calculator("") }
    malformed = Object.new
    malformed.define_singleton_method(:capabilities) { nil }
    malformed.define_singleton_method(:call) { |**| }
    assert_raises(ArgumentError) { RecordingStudioBilling.register_provider(:malformed, malformed) }
    refute RecordingStudioBilling.configuration.tax_policy.fetch(:enabled)

    RecordingStudioBilling.configuration.reset_registries!
    assert_empty RecordingStudioBilling.configuration.provider_registry.keys
    assert_empty RecordingStudioBilling.configuration.tax_calculator_registry.keys
  end

  test "provider capabilities return safe decisions and reject before invocation" do
    capabilities = RecordingStudioBilling::ProviderCapabilities.new(
      operations: :charge, currencies: :usd, markets: :us, collection_methods: :automatic,
      checkout_modes: :payment, tax_modes: :external, quantities: :fixed, composition: :single,
      refunds: :full, adjustments: :credit, constraints: { "maximum_quantity" => 10 }
    )
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success, capabilities:)
    supported = capabilities.evaluate(operation: :charge, currency: :usd, market: :us)
    unsupported = capabilities.evaluate(operation: :charge, currency: :eur)

    assert supported.supported?
    refute unsupported.supported?
    assert_equal "unsupported_currency", unsupported.reason
    assert_equal({ "maximum_quantity" => 10 }, unsupported.constraints)

    result = execute_provider(adapter:, capability_requirements: { operation: :charge, currency: :eur })
    assert_equal 0, adapter.calls
    assert_equal "unsupported_currency", result.command.reload.normalized_result.fetch("status")
  end

  test "every provider status is deterministic and unknown states remain unknown" do
    RecordingStudioBilling::AdapterResponse::STATUSES.each do |status|
      adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: status.to_sym)
      result = execute_provider(adapter:)
      assert_equal status, result.command.reload.normalized_result.fetch("status"), status
      assert_equal 1, adapter.calls, status
    end

    unknown = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :unknown_provider_state)
    result = execute_provider(adapter: unknown)
    assert_equal "unknown", result.command.reload.normalized_result.fetch("status")
    assert_equal "requires_reconciliation", result.command.state
  end

  test "provider calls use durable keys outside transactions and uncertain timeout is recoverable" do
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :duplicate)
    outside_transaction = nil
    result = execute_provider(
      adapter:,
      after_adapter_call: ->(*) { outside_transaction = !ActiveRecord::Base.connection.transaction_open? }
    )
    command = result.command.reload

    assert outside_transaction
    assert_equal [command.provider_idempotency_key], adapter.idempotency_keys
    timeout = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :timeout_after_possible_success)
    assert_raises(RecordingStudioBilling::FakeFinancialAdapter::TimeoutAfterPossibleSuccess) do
      execute_provider(adapter: timeout)
    end
    assert_equal "requires_reconciliation", RecordingStudioBilling::FinancialCommand.order(:created_at).last.state
  end

  test "tax is off by default and unknown or unsupported tax never assumes zero" do
    root, account, manifest = tax_authority
    result = RecordingStudioBilling.calculate_tax(calculator_key: :missing, **tax_request(root:, account:, manifest:))

    assert_equal :unsupported_tax_calculation, result.status
    assert_nil result.calculation
    refute_includes result.response, "tax_minor"

    calculator = RecordingStudioBilling::FakeTaxCalculator.new(outcome: :exclusive)
    enable_calculator(:external_tax, calculator)
    unsupported = RecordingStudioBilling.calculate_tax(
      calculator_key: :external_tax, **tax_request(root:, account:, manifest:).merge(currency: "JPY")
    )
    assert_equal :unsupported_tax_calculation, unsupported.status
    assert_equal 0, calculator.calls
  end

  test "tax requests reject client authority unsafe values floats and cross-root records" do
    root, account, manifest = tax_authority
    attributes = tax_request(root:, account:, manifest:)

    assert_raises(ArgumentError) do
      RecordingStudioBilling::TaxRequest.new(**attributes.merge(client_payload: { tax_total: 1 }))
    end
    assert_raises(RecordingStudioBilling::SafeFinancialPayload::UnsafeValue) do
      RecordingStudioBilling::TaxRequest.new(**attributes.merge(client_payload: { note: { token: "secret" } }))
    end
    assert_raises(ArgumentError) do
      RecordingStudioBilling::TaxRequest.new(**attributes.merge(subtotal_minor: 1_000.0))
    end
    other_root, other_account, other_manifest = tax_authority
    assert_raises(ArgumentError) do
      RecordingStudioBilling::TaxRequest.new(**attributes.merge(account_recording: other_account.recording))
    end
    assert_raises(ArgumentError) do
      RecordingStudioBilling::TaxRequest.new(**attributes.merge(manifest: other_manifest))
    end
    refute_equal root.id, other_root.id
  end

  test "integer inclusive and exclusive tax arithmetic is enforced" do
    common = {
      status: :success, subtotal_minor: 1_000, discount_minor: 100, tax_minor: 90,
      currency: "USD", calculator_reference: "safe-reference", calculated_at: Time.current,
      request_fingerprint: "a" * 64
    }
    exclusive = RecordingStudioBilling::TaxResponse.new(**common.merge(behavior: :exclusive, total_minor: 990))
    inclusive = RecordingStudioBilling::TaxResponse.new(**common.merge(behavior: :inclusive, total_minor: 900))

    assert_equal 990, exclusive.total_minor
    assert_equal 900, inclusive.total_minor
    assert_raises(ArgumentError) do
      RecordingStudioBilling::TaxResponse.new(**common.merge(behavior: :exclusive, total_minor: 900))
    end
    assert_raises(ArgumentError) do
      RecordingStudioBilling::TaxResponse.new(**common.merge(behavior: :exclusive, total_minor: 990.0))
    end
  end

  test "completed and pending calculations persist idempotently and conflicts fail closed" do
    root, account, manifest = tax_authority
    calculator = RecordingStudioBilling::FakeTaxCalculator.new(outcome: :exclusive)
    enable_calculator(:external_tax, calculator)
    attributes = tax_request(root:, account:, manifest:)

    first = RecordingStudioBilling.calculate_tax(calculator_key: :external_tax, **attributes)
    retry_result = RecordingStudioBilling.calculate_tax(calculator_key: :external_tax, **attributes)
    conflict = RecordingStudioBilling.calculate_tax(
      calculator_key: :external_tax, **attributes.merge(operation_reference: "different")
    )

    assert first.final?
    assert_equal first.calculation, retry_result.calculation
    assert_equal :conflict, conflict.status
    assert_equal 1, calculator.calls
    assert_equal 1, RecordingStudioBilling::TaxCalculation.count

    pending = RecordingStudioBilling::FakeTaxCalculator.new(outcome: %i[pending exclusive])
    enable_calculator(:pending_tax, pending)
    pending_result = RecordingStudioBilling.calculate_tax(
      calculator_key: :pending_tax, **attributes.merge(idempotency_key: SecureRandom.uuid)
    )
    refute pending_result.final?
    assert_equal "pending", pending_result.calculation.status

    recovered = RecordingStudioBilling.recover_tax_calculation(calculation: pending_result.calculation)
    assert recovered.final?
    assert_equal 2, recovered.calculation.revision_number
    assert_equal pending_result.calculation, recovered.calculation.supersedes
    assert_equal "pending", pending_result.calculation.reload.status
    assert_equal 2, pending.idempotency_keys.length
    assert_equal 1, pending.idempotency_keys.uniq.length
  end

  test "provider-calculated tax is authoritative and history is database immutable" do
    root, account, manifest = tax_authority
    calculator = RecordingStudioBilling::FakeTaxCalculator.new(outcome: :provider_calculated)
    enable_calculator(:provider_tax, calculator)
    result = RecordingStudioBilling.calculate_tax(
      calculator_key: :provider_tax, **tax_request(root:, account:, manifest:)
    )
    calculation = result.calculation

    assert_equal "provider_calculation", calculation.calculator_mode
    assert_equal true, calculation.safe_metadata.fetch("authoritative")
    assert_raises(ActiveRecord::StatementInvalid) { calculation.update_column(:tax_minor, 0) }
    assert_raises(ActiveRecord::StatementInvalid) { calculation.delete }

    forged = calculation.attributes.except("id", "created_at", "updated_at").merge(
      "revision_number" => 2, "supersedes_id" => calculation.id,
      "operation_reference" => "forged-operation", "created_at" => Time.current, "updated_at" => Time.current
    )
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::TaxCalculation.insert_all!([forged.merge("id" => SecureRandom.uuid)])
    end
  end

  test "mismatched calculator results remain uncertain and are never tax history" do
    root, account, manifest = tax_authority

    %i[mismatched_subtotal mismatched_total mismatched_currency].each do |outcome|
      calculator = RecordingStudioBilling::FakeTaxCalculator.new(outcome:)
      enable_calculator(outcome, calculator)
      result = RecordingStudioBilling.calculate_tax(
        calculator_key: outcome,
        **tax_request(root:, account:, manifest:).merge(idempotency_key: SecureRandom.uuid)
      )
      assert_equal :unsupported_tax_calculation, result.status, outcome
      assert_nil result.calculation, outcome
      assert_equal "requires_reconciliation", RecordingStudioBilling::FinancialCommand.order(:created_at).last.state
    end

    assert_equal 0, RecordingStudioBilling::TaxCalculation.count
  end

  test "safe persistence and source boundaries exclude sensitive provider and compliance coupling" do
    task_files = Dir[File.expand_path("../{app,db}/**/{*provider*,*tax*}", __dir__)].select { |path| File.file?(path) }
    task_source = task_files.map { |path| File.read(path) }.join

    refute_match(/Stripe::|stripe_tax|checkout_intent|webhook/i, task_source)
    refute_match(/nexus|registration|remittance|tax_return|filing_dashboard/i, task_source)
    refute_match(/api[_-]?key|access[_-]?token|provider_url|raw_provider/i,
                 RecordingStudioBilling::TaxCalculation.pluck(:safe_metadata, :breakdown).inspect)
  end

  test "provider execution and recovery reject wrong keys and ProviderAccount substitution" do
    root, account, = tax_authority
    alpha = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success)
    beta = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :duplicate)
    RecordingStudioBilling.register_provider(:alpha, alpha)
    RecordingStudioBilling.register_provider(:beta, beta)
    provider_recording = provider_authority(adapter_key: "alpha")
    attributes = {
      root_recording: root, account_recording: account.recording, command_type: "provider_contract",
      provider_account_recording: provider_recording, provider_adapter_key: "alpha",
      local_idempotency_key: SecureRandom.uuid, request: { approved_amount_minor: 500, currency: "USD" }
    }
    command = RecordingStudioBilling.create_financial_command(**attributes).command

    assert_raises(ArgumentError) do
      RecordingStudioBilling::FinancialCommandExecutor.execute(command:, provider_key: :beta)
    end
    assert_equal 0, beta.calls
    assert_raises(ArgumentError) do
      RecordingStudioBilling.create_financial_command(
        **attributes.merge(local_idempotency_key: SecureRandom.uuid, provider_adapter_key: "beta")
      )
    end

    RecordingStudioBilling::FinancialCommandExecutor.execute(command:, provider_key: :alpha)
    pending_adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :pending)
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider(:alpha, pending_adapter)
    pending_command = RecordingStudioBilling.execute_financial_command(
      provider_key: :alpha, **attributes.merge(local_idempotency_key: SecureRandom.uuid)
    ).command.reload
    assert_raises(ArgumentError) do
      RecordingStudioBilling.recover_financial_command(command: pending_command, provider_key: :beta)
    end
  end

  test "tax recovery is bound to the original registered key and mode" do
    root, account, manifest = tax_authority
    pending = RecordingStudioBilling::FakeTaxCalculator.new(outcome: :pending)
    enable_calculator(:bound_tax, pending)
    result = RecordingStudioBilling.calculate_tax(
      calculator_key: :bound_tax, **tax_request(root:, account:, manifest:)
    )

    RecordingStudioBilling.configuration.tax_calculator_registry.reset!
    RecordingStudioBilling.register_tax_calculator(:other_tax, pending)
    assert_raises(ArgumentError) do
      RecordingStudioBilling.recover_tax_calculation(calculation: result.calculation)
    end

    wrong_mode = RecordingStudioBilling::FakeTaxCalculator.new(
      outcome: :provider_calculated,
      capabilities: RecordingStudioBilling::TaxCalculatorCapabilities.new(
        mode: :provider_calculation, transactions: %w[sale], currencies: %w[USD], markets: %w[US],
        behaviors: %w[exclusive], location: true, classification: true
      )
    )
    RecordingStudioBilling.configuration.tax_calculator_registry.reset!
    RecordingStudioBilling.register_tax_calculator(:bound_tax, wrong_mode)
    assert_raises(ArgumentError) do
      RecordingStudioBilling.recover_tax_calculation(calculation: result.calculation)
    end
    assert_equal 0, wrong_mode.calls
  end

  test "concurrent identical tax calls block and invoke the calculator once" do
    root, account, manifest = tax_authority
    entered = Queue.new
    release = Queue.new
    calculator = BlockingTaxCalculator.new(outcome: :exclusive, entered:, release:)
    enable_calculator(:blocking_tax, calculator)
    attributes = tax_request(root:, account:, manifest:)
    ready = Queue.new
    results = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          results << RecordingStudioBilling.calculate_tax(calculator_key: :blocking_tax, **attributes)
        end
      end
    end
    2.times { ready.pop }
    entered.pop
    assert_equal 1, calculator.entered_calls
    release << true
    threads.each(&:join)

    calculations = 2.times.map { results.pop.calculation }
    assert_equal 1, calculator.calls
    assert_equal 1, calculator.entered_calls
    assert_equal 1, calculations.map(&:id).uniq.size
  end

  test "classification derives from line categories and fake clock is deterministic" do
    root, account, manifest = tax_authority
    attributes = tax_request(root:, account:, manifest:)
    assert_raises(ArgumentError) do
      RecordingStudioBilling::TaxRequest.new(**attributes.merge(tax_categories: %i[reduced standard]))
    end

    fixed_time = Time.zone.parse("2026-08-11 12:00:00 UTC")
    calculator = RecordingStudioBilling::FakeTaxCalculator.new(outcome: :exclusive, clock: -> { fixed_time })
    enable_calculator(:clock_tax, calculator)
    result = RecordingStudioBilling.calculate_tax(calculator_key: :clock_tax, **attributes)
    assert_equal fixed_time, result.calculation.calculated_at
  end

  test "unsafe URLs tax PII and raw provider data fail in Ruby and PostgreSQL" do
    root, account, manifest = tax_authority
    attributes = tax_request(root:, account:, manifest:)
    %i[provider_id tax_id email callback_url].each do |unsafe_key|
      assert_raises(RecordingStudioBilling::SafeFinancialPayload::UnsafeValue) do
        RecordingStudioBilling::TaxResponse.new(
          status: :success, subtotal_minor: 1_000, discount_minor: 100, tax_minor: 90,
          total_minor: 990, currency: "USD", behavior: :exclusive,
          calculator_reference: "safe-reference", calculated_at: Time.current,
          request_fingerprint: "a" * 64, metadata: { unsafe_key => "unsafe" }
        )
      end
    end
    assert_raises(RecordingStudioBilling::SafeFinancialPayload::UnsafeValue) do
      RecordingStudioBilling::TaxRequest.new(**attributes.merge(operation_reference: "https://example.test/raw"))
    end

    calculator = RecordingStudioBilling::FakeTaxCalculator.new(outcome: :exclusive)
    enable_calculator(:secure_tax, calculator)
    calculation = RecordingStudioBilling.calculate_tax(calculator_key: :secure_tax, **attributes).calculation
    forged = calculation.attributes.except("id", "created_at", "updated_at").merge(
      "id" => SecureRandom.uuid, "revision_number" => 2, "supersedes_id" => calculation.id,
      "safe_metadata" => { "email" => "person@example.test" },
      "created_at" => Time.current, "updated_at" => Time.current
    )
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::TaxCalculation.insert_all!([forged])
    end
  end

  private

  def execute_provider(adapter:, capability_requirements: {}, after_adapter_call: nil)
    root, account, = tax_authority
    key = "provider_contract"
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider(key, adapter)
    RecordingStudioBilling.execute_financial_command(
      provider_key: key, capability_requirements:, after_adapter_call:, root_recording: root,
      account_recording: account.recording, command_type: "provider_contract",
      provider_account_recording: provider_authority(adapter_key: key),
      local_idempotency_key: SecureRandom.uuid,
      request: { approved_amount_minor: 500, currency: "USD" }
    )
  end

  def provider_authority(adapter_key:)
    root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider root #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: root, key: "admin_#{SecureRandom.hex(4)}")
    provider = RecordingStudioBilling::ProviderAccount.new(
      billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}",
      adapter_key:, name: "Test provider", environment: "test", configuration: {}, capabilities: [],
      supported_markets: [], supported_currencies: []
    )
    RecordingStudio.record!(
      action: "created", recordable: provider, root_recording: root, parent_recording: admin.recording
    ).recording
  end

  def tax_authority
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Tax root #{SecureRandom.hex(4)}"))
    account = RecordingStudioBilling.ensure_account(root_recording: root, name: "Tax account")
    data = { "approved_amount_minor" => 1_000 }
    snapshots = [{ "recording_id" => root.id }]
    references = { "root" => { "recording_id" => root.id } }
    envelope = {
      "schema_version" => "v1", "resolver_version" => "v1", "root_recording_id" => root.id,
      "canonical_data" => data, "recording_snapshots" => snapshots, "snapshot_references" => references
    }
    manifest = RecordingStudioBilling::CommercialManifest.create!(
      root_recording_id: root.id, schema_version: "v1", resolver_version: "v1",
      canonical_data: data, recording_snapshots: snapshots, snapshot_references: references,
      manifest_digest: RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope), used_at: Time.current
    )
    [root, account, manifest]
  end

  def tax_request(root:, account:, manifest:)
    {
      root_recording: root, account_recording: account.recording, manifest:, transaction_type: :sale,
      operation_reference: "sale-#{SecureRandom.uuid}",
      lines: [{ reference: "line-1", quantity: 1, amount_minor: 1_000, tax_category: :standard }],
      subtotal_minor: 1_000, discount_minor: 100, currency: "USD",
      verified_location: { country: "US", region: "NY" }, tax_categories: [:standard],
      behavior: :exclusive, effective_at: Time.current, idempotency_key: SecureRandom.uuid
    }
  end

  def enable_calculator(key, calculator)
    RecordingStudioBilling.configuration.tax_calculator_registry.reset!
    RecordingStudioBilling.register_tax_calculator(key, calculator)
    RecordingStudioBilling.configuration.tax_policy = { enabled: true, calculator_key: key }
  end

  def clear_data!
    connection = ActiveRecord::Base.connection
    tables = [
      RecordingStudioBilling::TaxCalculation.table_name,
      RecordingStudioBilling::FinancialCommand.table_name,
      RecordingStudioBilling::CommercialManifest.table_name
    ]
    connection.execute("TRUNCATE TABLE #{tables.map { |table| connection.quote_table_name(table) }.join(', ')} RESTART IDENTITY CASCADE")
    RecordingStudio::Event.unscoped.delete_all
    RecordingStudioBilling::ProviderAccount.delete_all
    RecordingStudioBilling::BillingAdmin.delete_all
    RecordingStudioBilling::Account.delete_all
    RecordingStudio::Recording.unscoped.delete_all
    Workspace.delete_all
    AdminRoot.delete_all
  end
end
