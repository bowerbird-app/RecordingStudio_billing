# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class CommercialDeliveryTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ActiveSupport::Testing::TimeHelpers

  setup do
    clear_data!
    RecordingStudioBilling.configuration.feature_definitions = {
      "projects" => {
        source: "catalogue", merge_rule: "replace", default: 1, type: "limit",
        meter_key: nil, usage_unit_key: nil, replenishment: "none", lifecycle: "subscription",
        consumption: "none", ordering: 1, validation: { "minimum" => 0 }
      }
    }
    RecordingStudioBilling.configuration.tax_policy = {}
  end

  teardown { clear_data! }

  test "canonical manifests are deterministic, versioned, digest verified, and immutable" do
    first = { b: BigDecimal("12.50"), a: Time.utc(2026, 1, 2, 3, 4, 5) }
    second = { "a" => Time.utc(2026, 1, 2, 3, 4, 5), "b" => BigDecimal("12.5") }

    assert_equal RecordingStudioBilling::CommercialManifestCanonicalizer.digest(first),
                 RecordingStudioBilling::CommercialManifestCanonicalizer.digest(second)
    assert_raises(RecordingStudioBilling::CommercialManifestCanonicalizer::UnsupportedValue) do
      RecordingStudioBilling::CommercialManifestCanonicalizer.canonicalize(1.25)
    end

    data = JSON.parse(RecordingStudioBilling::CommercialManifestCanonicalizer.canonicalize("price" => 100))
    snapshots = [{ "recording_id" => SecureRandom.uuid }]
    references = { "recording" => {} }
    envelope = {
      "schema_version" => "v1", "resolver_version" => "v1", "root_recording_id" => SecureRandom.uuid,
      "canonical_data" => data, "recording_snapshots" => snapshots, "snapshot_references" => references
    }
    manifest = RecordingStudioBilling::CommercialManifest.create!(
      root_recording_id: envelope.fetch("root_recording_id"), schema_version: "v1", resolver_version: "v1",
      canonical_data: data, manifest_digest: RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope),
      recording_snapshots: snapshots, snapshot_references: references
    )
    assert_not manifest.update(schema_version: "v2")
    assert_includes manifest.errors[:base], "commercial manifests are immutable"
    assert_not RecordingStudioBilling::CommercialManifest.new(
      root_recording_id: SecureRandom.uuid, schema_version: "v2", resolver_version: "v1",
      canonical_data: data, manifest_digest: "0" * 64,
      recording_snapshots: [{ "recording_id" => SecureRandom.uuid }], snapshot_references: { "price" => {} }
    ).valid?
  end

  test "drafts fail closed and atomic publication creates used manifests and events" do
    graph = commercial_graph
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialManifestResolver.new(
        product: graph[:product], billing_option: graph[:option], price: graph[:italy_price],
        market: graph[:italy_market], currency_code: "EUR"
      ).resolve!
    end
    assert_match(/draft/, error.message)

    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id]
    )
    assert_predicate candidate, :activated?
    assert RecordingStudioBilling::Price.where(state: "published").exists?
    assert RecordingStudioBilling::CommercialManifest.where(used_at: ..Time.current).exists?
    assert RecordingStudio::Event.where(action: "commercial_published").exists?
    assert_raises(ActiveRecord::RecordInvalid) do
      RecordingStudioBilling::Price.find_by!(state: "published").update!(amount_minor: 999)
    end
  end

  test "an invalid graph rolls back every publication artifact" do
    graph = commercial_graph
    RecordingStudioBilling.configuration.feature_definitions = {}

    assert_raises(KeyError) do
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id]
      )
    end
    assert_equal 0, RecordingStudioBilling::CommercialManifest.count
    assert_equal 0, RecordingStudioBilling::CommercialPublicationCandidate.count
    assert_equal "draft", RecordingStudioBilling::Price.find_by!(key: "italy_eur_price").state
  end

  test "publication selection is explicit, idempotent, and leaves unrelated drafts untouched" do
    graph = commercial_graph
    effective_at = 5.minutes.from_now.change(usec: 0)
    selection = [graph[:italy_price].recording.id]

    first = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at:, price_recording_ids: selection
    )
    second = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at:, price_recording_ids: selection
    )

    assert_equal first.id, second.id
    assert_equal "draft", graph[:germany_price].reload.state
    assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root], effective_at:, price_recording_ids: [graph[:germany_price].recording.id]
      )
    end
  end

  test "candidate and manifest envelope tampering fails closed" do
    graph = commercial_graph
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at: 2.minutes.from_now,
      price_recording_ids: [graph[:italy_price].recording.id]
    )
    manifest = RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: candidate.manifest_digests.first)
    manifest.update_column(:canonical_data, manifest.canonical_data.merge("tampered" => true))

    travel_to(3.minutes.from_now) do
      error = assert_raises(ArgumentError) { RecordingStudioBilling::CommercialPublisher.activate!(candidate:) }
      assert_match(/manifest/, error.message)
    end
  end

  test "provider secrets nested in arrays are rejected" do
    provider = RecordingStudioBilling::ProviderAccount.new(
      billing_admin_recording_id: SecureRandom.uuid, key: "nested_secret_provider", adapter_key: "stripe",
      name: "Provider", environment: "production", configuration: { "nested" => [{ "token" => "nope" }] },
      capabilities: [], supported_markets: [], supported_currencies: []
    )

    assert_not provider.valid?
    assert_includes provider.errors[:configuration], "must not contain credentials or secrets"
  end

  test "scheduled activation is idempotent and stale candidates fail closed" do
    graph = commercial_graph
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at: 2.minutes.from_now,
      price_recording_ids: [graph[:italy_price].recording.id]
    )
    assert_not_predicate candidate, :activated?
    error = assert_raises(ArgumentError) { RecordingStudioBilling::CommercialPublisher.activate!(candidate: candidate) }
    assert_match(/not effective/, error.message)

    candidate.update_column(:effective_at, 1.minute.ago)
    error = assert_raises(ArgumentError) { RecordingStudioBilling::CommercialPublisher.activate!(candidate: candidate) }
    assert_match(/persisted terms/, error.message)
    assert_equal "draft", graph[:italy_price].recording.reload.recordable.state
  end

  test "scheduled activation is deterministic and does not duplicate events" do
    graph = commercial_graph
    effective_at = 2.minutes.from_now
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(root_recording: graph[:root],
                                                                     effective_at: effective_at,
                                                                     price_recording_ids: [graph[:italy_price].recording.id])

    travel_to(effective_at + 1.second) do
      RecordingStudioBilling::CommercialPublisher.activate!(candidate: candidate)
      events = RecordingStudio::Event.where(action: "commercial_published").count
      RecordingStudioBilling::CommercialPublisher.activate!(candidate: candidate.reload)
      assert_equal events, RecordingStudio::Event.where(action: "commercial_published").count
    end
  end

  test "market resolution selects distinct Italian and German EUR prices and requotes on finalization" do
    graph = commercial_graph
    graph[:provider] = publish_recordable(graph[:provider])
    graph[:italy_market] = publish_recordable(graph[:italy_market])
    graph[:germany_market] = publish_recordable(graph[:germany_market])
    graph[:italy_price] = publish_recordable(graph[:italy_price])
    graph[:germany_price] = publish_recordable(graph[:germany_price])
    resolver = RecordingStudioBilling::MarketResolver.new(markets: [graph[:italy_market], graph[:germany_market]])
    italy = resolver.resolve(stage: :display, declaration_country: "IT", explicit_currency: "EUR")
    germany = resolver.resolve(stage: :display, declaration_country: "DE", explicit_currency: "EUR")

    assert_equal graph[:italy_market], italy.market
    assert_equal graph[:germany_market], germany.market
    assert_equal graph[:italy_price].recording.id, RecordingStudioBilling::CommercialPriceSelector.new(
      billing_option: graph[:option], market: italy.market, currency_code: italy.currency_code
    ).price!.recording.id
    assert_equal graph[:germany_price].recording.id, RecordingStudioBilling::CommercialPriceSelector.new(
      billing_option: graph[:option], market: germany.market, currency_code: germany.currency_code
    ).price!.recording.id
    assert_equal :requote, resolver.resolve(
      stage: :final_charge, account_country: "DE", previous: italy
    ).outcome
    assert_raises(ArgumentError) do
      RecordingStudioBilling::MarketResolver.new(markets: [
                                                   graph[:italy_market],
                                                   graph[:italy_market].dup
                                                 ]).resolve(stage: :display, declaration_country: "IT", explicit_currency: "EUR")
    end
  end

  test "feature definitions fail closed, product rule vocabulary is exact, and tax is off by default" do
    assert_raises(KeyError) { RecordingStudioBilling::FeatureDefinitionRegistry.fetch!("unknown") }
    assert_equal %w[requires excludes available_with replaces upgrade_from downgrade_from same_family],
                 RecordingStudioBilling::ProductRule::RULE_TYPES
    assert_equal false, RecordingStudioBilling.configuration.tax_policy.fetch(:enabled)
    assert_equal "provider_default", RecordingStudioBilling.configuration.tax_policy.fetch(:presentation)
  end

  private

  def commercial_graph
    root = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Admin")))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: root, key: unique_name("billing"))
    admin_recording = admin.recording
    provider = record_child(
      RecordingStudioBilling::ProviderAccount.new(
        billing_admin_recording: admin_recording, key: unique_name("provider").tr(" ", "_"),
        adapter_key: "stripe", name: "Provider", environment: "production", configuration: { "merchant" => "catalogue" },
        capabilities: [], supported_markets: %w[IT DE], supported_currencies: ["EUR"]
      ), root, admin_recording
    )
    italy_market = market("italy", "IT", provider, root, admin_recording)
    germany_market = market("germany", "DE", provider, root, admin_recording)
    product = record_child(
      RecordingStudioBilling::Product.new(
        provider_account_recording: provider, key: unique_name("product").tr(" ", "_"), kind: "plan",
        feature_values: { "projects" => 3 }
      ), root, admin_recording
    )
    option = record_child(
      RecordingStudioBilling::BillingOption.new(
        product_recording: product, key: unique_name("monthly").tr(" ", "_"), recurrence: "recurring",
        interval: "month", interval_count: 1, quantity_mode: "fixed", default_quantity: 1,
        pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0, trial_days: 0,
        proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"
      ), root, product
    )
    feature = record_child(
      RecordingStudioBilling::Feature.new(
        product_recording: product, key: "projects", kind: "limit", definition: {}
      ), root, product
    )
    italy_price = price("italy", option, italy_market, 1_000, root)
    germany_price = price("germany", option, germany_market, 1_200, root)
    {
      root: root, product: product.recordable, option: option.recordable, feature: feature.recordable,
      provider: provider.recordable,
      italy_market: italy_market.recordable, germany_market: germany_market.recordable,
      italy_price: italy_price.recordable, germany_price: germany_price.recordable
    }
  end

  def market(name, country, provider, root, parent)
    record_child(
      RecordingStudioBilling::Market.new(
        provider_account_recording: provider, key: "#{name}_market", country_codes: [country],
        country_groups: {}, allowed_currency_codes: ["EUR"], default_currency_code: "EUR", priority: 10,
        specificity: 1, fallback: false, ppa_policy: "standard", rounding_policy: "half_up",
        tax_presentation_policy: "exclusive", verification_policy: "none"
      ), root, parent
    )
  end

  def price(name, option, market, amount, root)
    record_child(
      RecordingStudioBilling::Price.new(
        billing_option_recording: option, market_recording: market, key: "#{name}_eur_price",
        amount_minor: amount, currency_code: "EUR", currency_exponent: 2, pricing_model: "flat",
        version: 1, scope: "default"
      ), root, option
    )
  end

  def record_child(recordable, root, parent)
    RecordingStudio.record!(
      action: "created", recordable: recordable, root_recording: root, parent_recording: parent
    ).recording
  end

  def publish_recordable(recordable)
    recordable.recording.root_recording.revise(recordable.recording) { |revision| revision.state = "published" }
    recordable.recording.reload.recordable
  end

  def clear_data!
    RecordingStudioBilling::CommercialPublicationCandidate.delete_all
    RecordingStudioBilling::CommercialManifest.delete_all
    RecordingStudio::Event.unscoped.delete_all
    [
      RecordingStudioBilling::CostRate, RecordingStudioBilling::CostCard, RecordingStudioBilling::Rate,
      RecordingStudioBilling::RateCard, RecordingStudioBilling::Meter, RecordingStudioBilling::UsageUnit,
      RecordingStudioBilling::PlanUpdate, RecordingStudioBilling::ProductRule,
      RecordingStudioBilling::FeatureOverride, RecordingStudioBilling::OveragePrice, RecordingStudioBilling::Price,
      RecordingStudioBilling::Feature, RecordingStudioBilling::BillingOption, RecordingStudioBilling::Product,
      RecordingStudioBilling::Market, RecordingStudioBilling::ProviderAccount, RecordingStudioBilling::BillingAdmin,
      RecordingStudioBilling::Account
    ].each(&:delete_all)
    RecordingStudio::Recording.unscoped.delete_all
    AdminRoot.delete_all
  end

  def unique_name(prefix)
    "#{prefix}_#{SecureRandom.hex(4)}"
  end
end
