# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require "rails/test_help"

class RatedUsageSettlementTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  class Adapter
    attr_reader :calls, :capabilities

    def initialize(capabilities:)
      @capabilities = capabilities
      @calls = 0
    end

    def call(**)
      @calls += 1
    end
  end

  setup do
    acquire_database_lock!
    clear_data!
    RecordingStudioBilling.configuration.reset_registries!
  end

  teardown do
    clear_data!
    RecordingStudioBilling.configuration.reset_registries!
  ensure
    release_database_lock!
  end

  test "creates one frozen provider-neutral collection command without calling an adapter" do
    root, account, rated_usage, provider = rated_usage_authority
    adapter = register_adapter(capabilities: supported_capabilities)
    close_period_for(rated_usage)

    result = RecordingStudioBilling.create_rated_usage_settlement(root_recording: account, rated_usage:,
                                                                  metadata: { "source" => "metering" })

    assert result.created?, result.inspect
    assert_equal 0, adapter.calls
    assert_equal root.id, result.settlement.root_recording_id
    assert_equal account.recording.id, result.settlement.account_recording_id
    assert_equal rated_usage.meter_aggregation.window_starts_at, result.settlement.usage_period.starts_at
    assert_equal provider.id, result.command.provider_account_recording_id
    assert_equal "usage_settlement", result.command.command_type
    assert_equal 12, result.command.canonical_request.dig("request", "amount_minor")
    assert_equal "USD", result.command.canonical_request.dig("request", "currency")
    assert_equal [rated_usage.manifest_digest],
                 result.command.canonical_request.dig("request", "commercial_manifest_digests")
    assert_equal rated_usage.window_starts_at.utc.iso8601(6),
                 result.command.canonical_request.dig("request", "window_starts_at")
    assert_equal [rated_usage.manifest_digest],
                 result.command.canonical_request.dig("authority", "commercial_manifest_digests")
    assert_equal 0, RecordingStudioBilling::FinancialCommandAttempt.count
  end

  test "is idempotent and database authority rejects forged or mutable settlement history" do
    root, account, rated_usage, = rated_usage_authority
    register_adapter(capabilities: supported_capabilities)
    close_period_for(rated_usage)
    created = RecordingStudioBilling.create_rated_usage_settlement(root_recording: root, rated_usage:)
    existing = RecordingStudioBilling.create_rated_usage_settlement(root_recording: account.recording,
                                                                    rated_usage: rated_usage.id)

    assert created.created?
    assert existing.existing?
    assert_equal created.settlement.id, existing.settlement.id
    assert_equal 1, RecordingStudioBilling::RatedUsageSettlement.count

    forged = created.settlement.attributes.slice("root_recording_id", "account_recording_id", "rated_usage_id",
                                                 "financial_command_id", "provider_account_recording_id", "manifest_digest", "canonical_request", "request_fingerprint", "safe_metadata", "created_at", "updated_at").merge("id" => SecureRandom.uuid)
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::RatedUsageSettlement.insert_all!([forged.merge("canonical_request" => forged.fetch("canonical_request").merge("amount_minor" => 99))])
    end
    assert_raises(ActiveRecord::StatementInvalid) { created.settlement.update_column(:manifest_digest, "0" * 64) }
    assert_raises(ActiveRecord::StatementInvalid) { created.settlement.delete }
  end

  test "serializes concurrent settlement creation for one rated usage" do
    root, _account, rated_usage, = rated_usage_authority
    register_adapter(capabilities: supported_capabilities)
    close_period_for(rated_usage)
    ready = Queue.new
    release = Queue.new
    results = Queue.new

    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          results << RecordingStudioBilling.create_rated_usage_settlement(root_recording: root,
                                                                          rated_usage: rated_usage.id)
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    workers.each(&:join)

    assert_equal %i[created existing], 2.times.map { results.pop.status }.sort
    assert_equal 1, RecordingStudioBilling::RatedUsageSettlement.count
    assert_equal 1, RecordingStudioBilling::FinancialCommand.count
  end

  test "allocates expiring allowances in order into an append-only period ledger" do
    root, account, rated_usage, = rated_usage_authority
    early = RecordingStudioBilling::UsageCreditGrant.create!(
      root_recording: root, account_recording: account.recording, credit_key: "settlement", quantity: 2,
      remaining_quantity: 2, effective_at: rated_usage.window_starts_at - 1.hour, expires_at: rated_usage.window_ends_at,
      source_key: "early-#{SecureRandom.uuid}", safe_metadata: {}
    )
    late = RecordingStudioBilling::UsageCreditGrant.create!(
      root_recording: root, account_recording: account.recording, credit_key: "settlement", quantity: 3,
      remaining_quantity: 3, effective_at: rated_usage.window_starts_at - 1.hour, expires_at: rated_usage.window_ends_at + 1.hour,
      source_key: "late-#{SecureRandom.uuid}", safe_metadata: {}
    )

    result = RecordingStudioBilling.allocate_rated_usage(rated_usage:)
    allocation = result.allocation

    assert result.created?
    assert_equal [2, 3], allocation.usage_credit_allocations.order(:created_at, :id).pluck(:quantity)
    assert_equal [early.id, late.id],
                 allocation.usage_credit_allocations.order(:created_at, :id).pluck(:usage_credit_grant_id)
    assert_equal 5, allocation.credited_quantity
    assert_equal 1, allocation.excess_quantity
    assert_equal "open", allocation.usage_period.state
    assert_equal %w[consume consume overage], allocation.usage_ledger_entries.order(:sequence).pluck(:entry_kind)
    assert_raises(ActiveRecord::StatementInvalid) { allocation.usage_ledger_entries.first.update_column(:quantity, 1) }
    assert_raises(ActiveRecord::StatementInvalid) { early.update_column(:remaining_quantity, 1) }
  end

  test "closes a period under lock after allocation and retains idempotent close semantics" do
    _root, _account, rated_usage, = rated_usage_authority
    allocation = RecordingStudioBilling.allocate_rated_usage(rated_usage:).allocation

    early = RecordingStudioBilling::CloseUsagePeriod.call(usage_period: allocation.usage_period)
    assert early.blocked?
    closed = RecordingStudioBilling::CloseUsagePeriod.call(usage_period: allocation.usage_period,
                                                           at: allocation.usage_period.ends_at)
    existing = RecordingStudioBilling::CloseUsagePeriod.call(usage_period: allocation.usage_period)

    assert closed.closed?
    assert_equal "closed", closed.usage_period.state
    assert closed.usage_period.closed_at
    assert existing.existing?
  end

  test "calculates 3,400 excess units at two minor units per thousand as 680 minor units" do
    _root, _account, rated_usage, = rated_usage_authority
    allocation = RecordingStudioBilling.allocate_rated_usage(rated_usage:).allocation
    allocation.update!(measured_quantity: 3400, credited_quantity: 0, excess_quantity: 3400)

    overage = RecordingStudioBilling.calculate_overage(
      allocation:,
      rate: { "amount_minor" => 200, "package_size" => 1000, "currency_code" => "USD", "currency_exponent" => 2 }
    )

    assert_equal 3400, overage.excess_quantity
    assert_equal 680, overage.amount_minor
  end

  test "uses the frozen settled rate for cumulative usage correction amounts" do
    root, _account, rated_usage, = rated_usage_authority(customer_rate: {
                                                           "amount_minor" => 200, "package_size" => 1000, "currency_code" => "USD", "currency_exponent" => 2
                                                         })
    register_adapter(capabilities: supported_capabilities)
    close_period_for(rated_usage)
    settlement = RecordingStudioBilling.create_rated_usage_settlement(root_recording: root, rated_usage:)
    allocation = RecordingStudioBilling::UsageAllocation.find_by!(rated_usage:)

    first = RecordingStudioBilling.create_usage_correction(
      usage_allocation: allocation, correction_kind: "credit", quantity_delta: -1, reason: "late_meter_reading"
    )
    second = RecordingStudioBilling.create_usage_correction(
      usage_allocation: allocation, correction_kind: "credit", quantity_delta: -1, reason: "duplicate_meter_reading"
    )

    assert settlement.created?
    assert first.created?
    assert second.created?
    assert_equal(-1, first.command.canonical_request.dig("request", "amount_minor"))
    assert_equal(-1, first.command.canonical_request.dig("request", "cumulative_amount_minor"))
    assert_equal 0, second.command.canonical_request.dig("request", "amount_minor")
    assert_equal(-1, second.command.canonical_request.dig("request", "cumulative_amount_minor"))
  end

  test "records the selected route for late usage instead of treating it as timely" do
    root, _account, rated_usage, = rated_usage_authority
    period = close_period_for(rated_usage)
    period.update!(safe_metadata: { "late_usage_policy" => "next_invoice" })

    event = with_entitlement do
      RecordingStudioBilling.record_usage(
        root_recording: root, usage_key: "settlement", quantity: 1,
        idempotency_key: SecureRandom.uuid, occurred_at: period.starts_at + 1.minute
      ).event
    end

    assert_equal "late", event.classification
    assert_equal period.id, event.late_usage_period_id
    assert_equal "next_invoice", event.safe_metadata.fetch("late_usage_routing")
  end

  test "expires credits at the start of the next period and returns the same entry on replay" do
    root, account, rated_usage, = rated_usage_authority
    period = RecordingStudioBilling.allocate_rated_usage(rated_usage:).allocation.usage_period
    next_period = RecordingStudioBilling::UsagePeriod.create!(
      root_recording: root, account_recording: account.recording, usage_key: "settlement",
      starts_at: period.ends_at, ends_at: period.ends_at + 1.hour, state: "open", safe_metadata: {}
    )
    grant = RecordingStudioBilling::UsageCreditGrant.create!(
      root_recording: root, account_recording: account.recording, credit_key: "settlement", quantity: 2,
      remaining_quantity: 2, effective_at: period.starts_at, expires_at: period.ends_at,
      source_key: "expiry-#{SecureRandom.uuid}", safe_metadata: {}
    )

    expired = RecordingStudioBilling.expire_usage_credits(
      root_recording: root, account_recording: account.recording, credit_key: "settlement", at: period.ends_at
    )
    replayed = RecordingStudioBilling.expire_usage_credits(
      root_recording: root, account_recording: account.recording, credit_key: "settlement", at: period.ends_at
    )

    assert expired.expired?
    assert_equal [next_period.id], expired.entries.map(&:usage_period_id)
    assert_equal [grant.id], expired.entries.map(&:usage_credit_grant_id)
    assert replayed.existing?
    assert_equal expired.entries.map(&:id), replayed.entries.map(&:id)
  end

  test "fails closed for an untrusted webhook input" do
    _root, _account, _rated_usage, _provider = rated_usage_authority

    rejected = RecordingStudioBilling.apply_provider_webhook(
      inbound_event: Object.new, remote_type: "charge", remote_id: "missing"
    )

    assert rejected.rejected?
    assert_equal 0, RecordingStudioBilling::ReconciliationIssue.count
  end

  test "rejects cross-root inputs and safely gates missing or unsupported frozen capability" do
    root, _account, rated_usage, = rated_usage_authority
    other_root, = account_authority

    denied = RecordingStudioBilling.create_rated_usage_settlement(root_recording: other_root, rated_usage:)
    assert denied.denied?
    assert_equal 0, RecordingStudioBilling::RatedUsageSettlement.count
    assert_equal 0, RecordingStudioBilling::FinancialCommand.count

    close_period_for(rated_usage)
    unavailable = RecordingStudioBilling.create_rated_usage_settlement(root_recording: root, rated_usage:)
    assert unavailable.unsupported?
    assert_equal :provider_unavailable, unavailable.reason

    register_adapter(capabilities: RecordingStudioBilling::ProviderCapabilities.new(operations: ["checkout"]))
    unsupported = RecordingStudioBilling.create_rated_usage_settlement(root_recording: root, rated_usage:)
    assert unsupported.unsupported?
    assert_equal "unsupported_operation", unsupported.reason
    assert_equal 0, RecordingStudioBilling::RatedUsageSettlement.count
  end

  test "settles from published frozen usage terms after live catalogue revisions" do
    root, account = account_authority
    catalogue = published_settlement_catalogue
    usage_starts_at = Time.utc(2026, 8, 12, 12)
    usage_ends_at = usage_starts_at + 1.hour
    RecordingStudioBilling::UsageEvent.create!(
      root_recording: root, account_recording: account.recording, usage_key: "published_settlement",
      feature_key: "published_settlement", quantity: 4, occurred_at: usage_starts_at,
      idempotency_key: SecureRandom.uuid, safe_metadata: {}
    )

    rated_usage = with_entitlement do
      RecordingStudioBilling.rate_usage(
        root_recording: root, meter_recording: catalogue.fetch(:meter),
        manifest_digest: catalogue.fetch(:manifest).manifest_digest, window_starts_at: usage_starts_at,
        window_ends_at: usage_ends_at
      ).rated_usage
    end
    allocation = RecordingStudioBilling.allocate_rated_usage(rated_usage:).allocation
    overage = RecordingStudioBilling.calculate_overage(
      allocation:,
      rate: rated_usage.rate_snapshot.fetch("customer_rate")
    )
    frozen_terms = {
      amount_minor: overage.amount_minor, currency: overage.currency_code,
      exponent: overage.currency_exponent, manifest_digest: rated_usage.manifest_digest,
      provider_id: catalogue.fetch(:provider).id, adapter_key: "test", market_id: catalogue.fetch(:market).id,
      collection_method: "automatic", starts_at: rated_usage.window_starts_at.utc.iso8601(6),
      ends_at: rated_usage.window_ends_at.utc.iso8601(6)
    }

    catalogue.fetch(:root).revise(catalogue.fetch(:overage_price)) { |revision| revision.amount_minor = 99 }
    catalogue.fetch(:root).revise(catalogue.fetch(:rate)) { |revision| revision.conversion_numerator = 2 }
    catalogue.fetch(:root).revise(catalogue.fetch(:market)) { |revision| revision.country_codes = ["CA"] }

    adapter = register_adapter(capabilities: supported_capabilities)
    RecordingStudioBilling::CloseUsagePeriod.call(usage_period: allocation.usage_period,
                                                  at: allocation.usage_period.ends_at)
    result = RecordingStudioBilling.create_rated_usage_settlement(root_recording: root, rated_usage:)
    request = result.command.canonical_request.fetch("request")

    assert result.created?, result.inspect
    assert_equal 8, frozen_terms.fetch(:amount_minor)
    assert_equal frozen_terms.fetch(:amount_minor), request.fetch("amount_minor")
    assert_equal frozen_terms.fetch(:currency), request.fetch("currency")
    assert_equal frozen_terms.fetch(:exponent), request.fetch("currency_exponent")
    assert_equal frozen_terms.fetch(:starts_at), request.fetch("window_starts_at")
    assert_equal frozen_terms.fetch(:ends_at), request.fetch("window_ends_at")
    assert_equal frozen_terms.fetch(:manifest_digest), result.settlement.manifest_digest
    assert_equal [frozen_terms.fetch(:manifest_digest)],
                 result.command.canonical_request.dig("authority", "commercial_manifest_digests")
    assert_equal frozen_terms.fetch(:provider_id), result.settlement.provider_account_recording_id
    assert_equal frozen_terms.fetch(:provider_id), result.command.provider_account_recording_id
    assert_equal frozen_terms.fetch(:adapter_key), result.command.provider_adapter_key
    assert_equal frozen_terms.fetch(:market_id), request.fetch("market_recording_id")
    assert_equal frozen_terms.fetch(:collection_method), request.fetch("collection_method")
    assert_equal 0, adapter.calls
    assert_equal 1, RecordingStudioBilling::RatedUsageSettlement.count
    assert_equal 1, RecordingStudioBilling::FinancialCommand.count
  end

  private

  def clear_data!
    BillingTestDatabaseCleanup.clear!
  end

  def acquire_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(1_208_120_200)")
  end

  def release_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(1_208_120_200)")
  end

  def account_authority
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Settlement #{SecureRandom.hex(4)}"))
    account = RecordingStudioBilling.ensure_account(root_recording: root, name: "Billing")
    [RecordingStudio::Recording.unscoped.find(root.id), RecordingStudioBilling::Account.find(account.id)]
  end

  def close_period_for(rated_usage)
    allocation = RecordingStudioBilling.allocate_rated_usage(rated_usage:).allocation
    RecordingStudioBilling::CloseUsagePeriod.call(usage_period: allocation.usage_period,
                                                  at: allocation.usage_period.ends_at)
    allocation.usage_period.reload
  end

  def rated_usage_authority(customer_rate: nil)
    root, account = account_authority
    provider = provider_authority
    meter_id = SecureRandom.uuid
    unit_id = SecureRandom.uuid
    rate_card_id = SecureRandom.uuid
    rate_id = SecureRandom.uuid
    price_id = SecureRandom.uuid
    starts_at = 1.day.from_now.change(min: 0, sec: 0)
    ends_at = starts_at + 1.hour
    customer_rate = {
      "customer_price_recording_id" => price_id, "usage_unit_recording_id" => unit_id, "amount_minor" => 2,
      "currency_code" => "USD", "currency_exponent" => 2, "pricing_model" => "per_unit", "package_size" => nil
    }.merge(customer_rate || {})
    canonical_data = {
      "tax_policy" => { "enabled" => false, "presentation" => "provider_default", "calculator_key" => nil,
                        "policy_version" => "v1", "semantic_categories" => [] },
      "usage_settlement" => { "provider_account_recording_id" => provider.id, "provider_adapter_key" => "test",
                              "market_recording_id" => SecureRandom.uuid, "resolved_country_code" => "US", "resolution_tier" => "exact", "market_geography" => { "country_codes" => ["US"], "country_groups" => {}, "regional_country_codes" => [], "global_fallback" => false }, "collection_method" => "automatic", "operation" => "collect_usage" },
      "usage_rating" => {
        "meters" => { meter_id => { "meter_recording_id" => meter_id, "usage_unit_recording_id" => unit_id, "aggregation" => "sum", "usage_key" => "settlement" } },
        "rate_cards" => { rate_card_id => { "key" => "rates" } },
        "rates" => { rate_id => { "rate_recording_id" => rate_id, "rate_card_recording_id" => rate_card_id, "usage_unit_recording_id" => unit_id, "conversion_numerator" => 1, "conversion_denominator" => 1, "conversion_decimal" => nil } },
        "cost_cards" => {}, "cost_rates" => {},
        "customer_rates" => { price_id => customer_rate }
      }
    }
    snapshots = [{ "fixture" => true }]
    references = { "fixture" => { "fixture" => true } }
    envelope = { "schema_version" => "v1", "resolver_version" => "v1", "root_recording_id" => root.id,
                 "canonical_data" => canonical_data, "recording_snapshots" => snapshots, "snapshot_references" => references }
    manifest = RecordingStudioBilling::CommercialManifest.create!(root_recording_id: root.id, schema_version: "v1",
                                                                  resolver_version: "v1", canonical_data:, recording_snapshots: snapshots, snapshot_references: references, manifest_digest: RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope))
    manifest.mark_used!
    access = Struct.new(:allowed) do
      def has_feature?(_key) = allowed
      def limit(_key) = nil
      def allowance(_key) = nil
    end.new(true)
    rated_usage = RecordingStudioBilling::EntitlementAccess.stub(:for, access) do
      RecordingStudioBilling.record_usage(
        root_recording: root, usage_key: "settlement", quantity: 6,
        idempotency_key: SecureRandom.uuid, occurred_at: starts_at
      )
      RecordingStudioBilling.rate_usage(root_recording: root, meter_recording: meter_id,
                                        manifest_digest: manifest.manifest_digest, window_starts_at: starts_at, window_ends_at: ends_at).rated_usage
    end
    [root, account, rated_usage, provider]
  end

  def provider_authority
    catalogue_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: catalogue_root, key: "billing")
    RecordingStudio.record!(action: "created",
                            recordable: RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: admin.recording, key: "test", adapter_key: "test", name: "Test", environment: "production", configuration: {}, capabilities: [], supported_markets: ["US"], supported_currencies: ["USD"]), root_recording: catalogue_root, parent_recording: admin.recording).recording
  end

  def published_settlement_catalogue
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
    actor = User.create!(email: "settlement-publisher-#{SecureRandom.hex(4)}@example.com", password: "Password1!",
                         password_confirmation: "Password1!")
    root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Settlement catalogue #{SecureRandom.hex(4)}"))
    billing_admin = RecordingStudioBilling.ensure_billing_admin(root_recording: root, key: "billing")
    provider = record_catalogue(
      RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: billing_admin.recording, key: "provider",
                                                  adapter_key: "test", name: "Provider", environment: "production", configuration: {}, capabilities: [], supported_markets: ["US"], supported_currencies: ["USD"]), root, billing_admin.recording
    )
    market = record_catalogue(
      RecordingStudioBilling::Market.new(provider_account_recording: provider, key: "us", country_codes: ["US"],
                                         country_groups: {}, regional_country_codes: [], global_fallback: false, allowed_currency_codes: ["USD"], default_currency_code: "USD", priority: 1, specificity: 1, ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive", verification_policy: "none"), root, billing_admin.recording
    )
    product = record_catalogue(
      RecordingStudioBilling::Product.new(provider_account_recording: provider, key: "usage", kind: "service",
                                          feature_values: {}), root, billing_admin.recording
    )
    option = record_catalogue(
      RecordingStudioBilling::BillingOption.new(product_recording: product, key: "usage", recurrence: "one_time",
                                                quantity_mode: "fixed", default_quantity: 1, pricing_model: "per_unit", collection_method: "automatic", payment_terms_days: 0, trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"), root, product
    )
    price = record_catalogue(
      RecordingStudioBilling::Price.new(billing_option_recording: option, market_recording: market, key: "base",
                                        amount_minor: 1, currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "default"), root, option
    )
    unit = record_catalogue(RecordingStudioBilling::UsageUnit.new(provider_account_recording: provider, key: "unit"),
                            root, billing_admin.recording)
    overage_price = record_catalogue(
      RecordingStudioBilling::OveragePrice.new(billing_option_recording: option, market_recording: market,
                                               usage_unit_recording: unit, key: "overage", amount_minor: 2, currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "default"), root, option
    )
    meter = record_catalogue(
      RecordingStudioBilling::Meter.new(usage_unit_recording: unit, key: "published_settlement",
                                        aggregation: "sum"), root, billing_admin.recording
    )
    rate_card = record_catalogue(
      RecordingStudioBilling::RateCard.new(provider_account_recording: provider,
                                           key: "rates"), root, billing_admin.recording
    )
    rate = record_catalogue(
      RecordingStudioBilling::Rate.new(rate_card_recording: rate_card, usage_unit_recording: unit, key: "conversion",
                                       conversion_numerator: 1, conversion_denominator: 1), root, rate_card
    )
    cost_card = record_catalogue(
      RecordingStudioBilling::CostCard.new(provider_account_recording: provider,
                                           key: "costs"), root, billing_admin.recording
    )
    record_catalogue(
      RecordingStudioBilling::CostRate.new(cost_card_recording: cost_card, usage_unit_recording: unit, key: "cost",
                                           amount_minor: 3, currency_code: "USD", currency_exponent: 2), root, cost_card
    )
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(root_recording: root,
                                                                     price_recording_ids: [price.id], actor:)

    { root:, manifest: RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: candidate.manifest_digests.sole), provider:, market:, overage_price:, meter:, rate: }
  end

  def record_catalogue(recordable, root, parent)
    RecordingStudio.record!(action: "created", recordable:, root_recording: root, parent_recording: parent).recording
  end

  def with_entitlement(&)
    access = Struct.new(:allowed) do
      def has_feature?(_key) = allowed
      def limit(_key) = nil
      def allowance(_key) = nil
    end.new(true)
    RecordingStudioBilling::EntitlementAccess.stub(:for, access, &)
  end

  def supported_capabilities
    RecordingStudioBilling::ProviderCapabilities.new(operations: ["collect_usage"], currencies: ["USD"],
                                                     markets: ["US"], collection_methods: ["automatic"])
  end

  def register_adapter(capabilities:)
    adapter = Adapter.new(capabilities:)
    RecordingStudioBilling.register_provider(:test, adapter)
    adapter
  end
end
