# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require "rails/test_help"

class RatedUsageSettlementTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class Adapter
    attr_reader :calls

    def initialize(capabilities:)
      @capabilities = capabilities
      @calls = 0
    end

    attr_reader :capabilities

    def call(**)
      @calls += 1
    end
  end

  setup do
    clear_data!
    RecordingStudioBilling.configuration.reset_registries!
  end

  teardown do
    clear_data!
    RecordingStudioBilling.configuration.reset_registries!
  end

  test "creates one frozen provider-neutral collection command without calling an adapter" do
    root, account, rated_usage, provider = rated_usage_authority
    adapter = register_adapter(capabilities: supported_capabilities)

    result = RecordingStudioBilling.create_rated_usage_settlement(root_recording: account, rated_usage:, metadata: { "source" => "metering" })

    assert result.created?, result.inspect
    assert_equal 0, adapter.calls
    assert_equal root.id, result.settlement.root_recording_id
    assert_equal account.recording.id, result.settlement.account_recording_id
    assert_equal rated_usage.id, result.settlement.rated_usage_id
    assert_equal provider.id, result.command.provider_account_recording_id
    assert_equal "usage_settlement", result.command.command_type
    assert_equal 12, result.command.canonical_request.dig("request", "amount_minor")
    assert_equal "USD", result.command.canonical_request.dig("request", "currency")
    assert_equal rated_usage.manifest_digest, result.command.canonical_request.dig("request", "manifest_digest")
    assert_equal rated_usage.window_starts_at.utc.iso8601(6), result.command.canonical_request.dig("request", "window_starts_at")
    assert_equal [rated_usage.manifest_digest], result.command.canonical_request.dig("authority", "commercial_manifest_digests")
    assert_equal 0, RecordingStudioBilling::FinancialCommandAttempt.count
  end

  test "is idempotent and database authority rejects forged or mutable settlement history" do
    root, account, rated_usage, = rated_usage_authority
    register_adapter(capabilities: supported_capabilities)
    created = RecordingStudioBilling.create_rated_usage_settlement(root_recording: root, rated_usage:)
    existing = RecordingStudioBilling.create_rated_usage_settlement(root_recording: account.recording, rated_usage: rated_usage.id)

    assert created.created?
    assert existing.existing?
    assert_equal created.settlement.id, existing.settlement.id
    assert_equal 1, RecordingStudioBilling::RatedUsageSettlement.count

    forged = created.settlement.attributes.slice("root_recording_id", "account_recording_id", "rated_usage_id", "financial_command_id", "provider_account_recording_id", "manifest_digest", "canonical_request", "request_fingerprint", "safe_metadata", "created_at", "updated_at").merge("id" => SecureRandom.uuid)
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::RatedUsageSettlement.insert_all!([forged.merge("canonical_request" => forged.fetch("canonical_request").merge("amount_minor" => 99))])
    end
    assert_raises(ActiveRecord::StatementInvalid) { created.settlement.update_column(:manifest_digest, "0" * 64) }
    assert_raises(ActiveRecord::StatementInvalid) { created.settlement.delete }
  end

  test "serializes concurrent settlement creation for one rated usage" do
    root, _account, rated_usage, = rated_usage_authority
    register_adapter(capabilities: supported_capabilities)
    ready = Queue.new
    release = Queue.new
    results = Queue.new

    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          results << RecordingStudioBilling.create_rated_usage_settlement(root_recording: root, rated_usage: rated_usage.id)
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

  test "rejects cross-root inputs and safely gates missing or unsupported frozen capability" do
    root, _account, rated_usage, = rated_usage_authority
    other_root, = account_authority

    denied = RecordingStudioBilling.create_rated_usage_settlement(root_recording: other_root, rated_usage:)
    assert denied.denied?
    assert_equal 0, RecordingStudioBilling::RatedUsageSettlement.count
    assert_equal 0, RecordingStudioBilling::FinancialCommand.count

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
    frozen_terms = {
      amount_minor: rated_usage.customer_amount_minor, currency: rated_usage.customer_currency_code,
      exponent: rated_usage.customer_currency_exponent, manifest_digest: rated_usage.manifest_digest,
      provider_id: catalogue.fetch(:provider).id, adapter_key: "test", market_id: catalogue.fetch(:market).id,
      collection_method: "automatic", starts_at: rated_usage.window_starts_at.utc.iso8601(6),
      ends_at: rated_usage.window_ends_at.utc.iso8601(6)
    }

    catalogue.fetch(:root).revise(catalogue.fetch(:overage_price)) { |revision| revision.amount_minor = 99 }
    catalogue.fetch(:root).revise(catalogue.fetch(:rate)) { |revision| revision.conversion_numerator = 2 }
    catalogue.fetch(:root).revise(catalogue.fetch(:market)) { |revision| revision.country_codes = ["CA"] }

    adapter = register_adapter(capabilities: supported_capabilities)
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
    assert_equal [frozen_terms.fetch(:manifest_digest)], result.command.canonical_request.dig("authority", "commercial_manifest_digests")
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
    connection = ActiveRecord::Base.connection
    tables = [RecordingStudioBilling::RatedUsageSettlement.table_name, RecordingStudioBilling::FinancialCommandAttempt.table_name,
              RecordingStudioBilling::FinancialCommand.table_name, RecordingStudioBilling::RatedUsage.table_name,
              RecordingStudioBilling::MeterAggregation.table_name, RecordingStudioBilling::UsageEvent.table_name,
              RecordingStudioBilling::CommercialPublicationCandidate.table_name,
              RecordingStudioBilling::CommercialManifest.table_name,
              *RecordingStudioBilling::RECORDABLE_TYPES.map(&:constantize).map(&:table_name)]
    connection.execute("TRUNCATE TABLE #{tables.map { |table| connection.quote_table_name(table) }.join(', ')} RESTART IDENTITY CASCADE")
    RecordingStudio::Event.unscoped.delete_all
    RecordingStudio::Recording.unscoped.delete_all
    Workspace.delete_all
    AdminRoot.delete_all
    User.delete_all
  end

  def account_authority
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Settlement #{SecureRandom.hex(4)}"))
    [root, RecordingStudioBilling.ensure_account(root_recording: root, name: "Billing")]
  end

  def rated_usage_authority
    root, account = account_authority
    provider = provider_authority
    meter_id = SecureRandom.uuid
    unit_id = SecureRandom.uuid
    rate_card_id = SecureRandom.uuid
    rate_id = SecureRandom.uuid
    price_id = SecureRandom.uuid
    starts_at = Time.utc(2026, 8, 12, 12)
    ends_at = starts_at + 1.hour
    canonical_data = {
      "usage_settlement" => { "provider_account_recording_id" => provider.id, "provider_adapter_key" => "test", "market_recording_id" => SecureRandom.uuid, "market_country_codes" => ["US"], "collection_method" => "automatic", "operation" => "collect_usage" },
      "usage_rating" => {
        "meters" => { meter_id => { "meter_recording_id" => meter_id, "usage_unit_recording_id" => unit_id, "aggregation" => "sum", "usage_key" => "settlement" } },
        "rate_cards" => { rate_card_id => { "key" => "rates" } },
        "rates" => { rate_id => { "rate_recording_id" => rate_id, "rate_card_recording_id" => rate_card_id, "usage_unit_recording_id" => unit_id, "conversion_numerator" => 1, "conversion_denominator" => 1, "conversion_decimal" => nil } },
        "cost_cards" => {}, "cost_rates" => {},
        "customer_rates" => { price_id => { "customer_price_recording_id" => price_id, "usage_unit_recording_id" => unit_id, "amount_minor" => 2, "currency_code" => "USD", "currency_exponent" => 2, "pricing_model" => "per_unit", "package_size" => nil } }
      }
    }
    snapshots = [{ "fixture" => true }]
    references = { "fixture" => { "fixture" => true } }
    envelope = { "schema_version" => "v1", "resolver_version" => "v1", "root_recording_id" => root.id, "canonical_data" => canonical_data, "recording_snapshots" => snapshots, "snapshot_references" => references }
    manifest = RecordingStudioBilling::CommercialManifest.create!(root_recording_id: root.id, schema_version: "v1", resolver_version: "v1", canonical_data:, recording_snapshots: snapshots, snapshot_references: references, manifest_digest: RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope))
    manifest.mark_used!
    RecordingStudioBilling::UsageEvent.create!(root_recording: root, account_recording: account.recording, usage_key: "settlement", feature_key: "settlement", quantity: 6, occurred_at: starts_at, idempotency_key: SecureRandom.uuid, safe_metadata: {})
    access = Struct.new(:allowed) { def has_feature?(_key) = allowed }.new(true)
    rated_usage = RecordingStudioBilling::EntitlementAccess.stub(:for, access) do
      RecordingStudioBilling.rate_usage(root_recording: root, meter_recording: meter_id, manifest_digest: manifest.manifest_digest, window_starts_at: starts_at, window_ends_at: ends_at).rated_usage
    end
    [root, account, rated_usage, provider]
  end

  def provider_authority
    catalogue_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: catalogue_root, key: "billing")
    RecordingStudio.record!(action: "created", recordable: RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: admin.recording, key: "test", adapter_key: "test", name: "Test", environment: "production", configuration: {}, capabilities: [], supported_markets: ["US"], supported_currencies: ["USD"]), root_recording: catalogue_root, parent_recording: admin.recording).recording
  end

  def published_settlement_catalogue
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
    actor = User.create!(email: "settlement-publisher-#{SecureRandom.hex(4)}@example.com", password: "Password1!", password_confirmation: "Password1!")
    root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Settlement catalogue #{SecureRandom.hex(4)}"))
    billing_admin = RecordingStudioBilling.ensure_billing_admin(root_recording: root, key: "billing")
    provider = record_catalogue(RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: billing_admin.recording, key: "provider", adapter_key: "test", name: "Provider", environment: "production", configuration: {}, capabilities: [], supported_markets: ["US"], supported_currencies: ["USD"]), root, billing_admin.recording)
    market = record_catalogue(RecordingStudioBilling::Market.new(provider_account_recording: provider, key: "us", country_codes: ["US"], country_groups: {}, allowed_currency_codes: ["USD"], default_currency_code: "USD", priority: 1, specificity: 1, fallback: false, ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive", verification_policy: "none"), root, billing_admin.recording)
    product = record_catalogue(RecordingStudioBilling::Product.new(provider_account_recording: provider, key: "usage", kind: "service", feature_values: {}), root, billing_admin.recording)
    option = record_catalogue(RecordingStudioBilling::BillingOption.new(product_recording: product, key: "usage", recurrence: "one_time", quantity_mode: "fixed", default_quantity: 1, pricing_model: "per_unit", collection_method: "automatic", payment_terms_days: 0, trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"), root, product)
    price = record_catalogue(RecordingStudioBilling::Price.new(billing_option_recording: option, market_recording: market, key: "base", amount_minor: 1, currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "default"), root, option)
    unit = record_catalogue(RecordingStudioBilling::UsageUnit.new(provider_account_recording: provider, key: "unit"), root, billing_admin.recording)
    overage_price = record_catalogue(RecordingStudioBilling::OveragePrice.new(billing_option_recording: option, market_recording: market, usage_unit_recording: unit, key: "overage", amount_minor: 2, currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "default"), root, option)
    meter = record_catalogue(RecordingStudioBilling::Meter.new(usage_unit_recording: unit, key: "published_settlement", aggregation: "sum"), root, billing_admin.recording)
    rate_card = record_catalogue(RecordingStudioBilling::RateCard.new(provider_account_recording: provider, key: "rates"), root, billing_admin.recording)
    rate = record_catalogue(RecordingStudioBilling::Rate.new(rate_card_recording: rate_card, usage_unit_recording: unit, key: "conversion", conversion_numerator: 1, conversion_denominator: 1), root, rate_card)
    cost_card = record_catalogue(RecordingStudioBilling::CostCard.new(provider_account_recording: provider, key: "costs"), root, billing_admin.recording)
    record_catalogue(RecordingStudioBilling::CostRate.new(cost_card_recording: cost_card, usage_unit_recording: unit, key: "cost", amount_minor: 3, currency_code: "USD", currency_exponent: 2), root, cost_card)
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(root_recording: root, price_recording_ids: [price.id], actor:)

    { root:, manifest: RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: candidate.manifest_digests.sole), provider:, market:, overage_price:, meter:, rate: }
  end

  def record_catalogue(recordable, root, parent)
    RecordingStudio.record!(action: "created", recordable:, root_recording: root, parent_recording: parent).recording
  end

  def with_entitlement
    access = Struct.new(:allowed) { def has_feature?(_key) = allowed }.new(true)
    RecordingStudioBilling::EntitlementAccess.stub(:for, access) { yield }
  end

  def supported_capabilities
    RecordingStudioBilling::ProviderCapabilities.new(operations: ["collect_usage"], currencies: ["USD"], markets: ["US"], collection_methods: ["automatic"])
  end

  def register_adapter(capabilities:)
    adapter = Adapter.new(capabilities:)
    RecordingStudioBilling.register_provider(:test, adapter)
    adapter
  end
end