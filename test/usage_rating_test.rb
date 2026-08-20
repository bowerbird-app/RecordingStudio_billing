# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class UsageRatingTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    acquire_database_lock!
    clear_data!
  end

  teardown do
    clear_data!
  ensure
    release_database_lock!
  end

  test "rates sum count maximum and latest windows deterministically" do
    { "sum" => 15, "count" => 3, "maximum" => 7, "latest" => 5 }.each do |mode, expected|
      root, account = account_authority
      manifest, meter_id = used_manifest(root:, mode:)
      usage_events(root, account, "meter_#{mode}", [3, 7, 5])

      result = with_entitlement do
        RecordingStudioBilling.rate_usage(root_recording: account, meter_recording: meter_id,
                                          manifest_digest: manifest.manifest_digest, window_starts_at: window_start, window_ends_at: window_end)
      end

      assert result.created?, mode
      assert_equal expected, result.aggregation.quantity, mode
      assert_equal expected, result.rated_usage.quantity, mode
      assert_nil result.rated_usage.customer_amount_minor, mode
      assert_equal expected * 3, result.rated_usage.cost_amount_minor, mode
      assert_nil result.rated_usage.customer_currency_code, mode
      assert_equal manifest.manifest_digest, result.rated_usage.manifest_digest, mode
    end
  end

  test "normalizes roots and serializes duplicate aggregation and rating" do
    root, account = account_authority
    manifest, meter_id = used_manifest(root:, mode: "sum")
    usage_events(root, account, "meter_sum", [4])
    ready = Queue.new
    release = Queue.new
    results = Queue.new

    with_entitlement do
      workers = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            release.pop
            results << RecordingStudioBilling.rate_usage(root_recording: account, meter_recording: meter_id,
                                                         manifest_digest: manifest.manifest_digest, window_starts_at: window_start, window_ends_at: window_end)
          end
        end
      end
      2.times { ready.pop }
      2.times { release << true }
      workers.each(&:join)
    end

    assert_equal %i[created existing], 2.times.map { results.pop.status }.sort
    assert_equal 1, RecordingStudioBilling::MeterAggregation.count
    assert_equal 1, RecordingStudioBilling::RatedUsage.count
    assert_equal root.id, RecordingStudioBilling::RatedUsage.sole.root_recording_id
  end

  test "fails closed for missing entitlement, missing authority, ambiguous terms, and non-integral rates" do
    root, account = account_authority
    manifest, meter_id = used_manifest(root:, mode: "sum")
    usage_events(root, account, "meter_sum", [3])

    denied = RecordingStudioBilling.rate_usage(root_recording: root, meter_recording: meter_id,
                                               manifest_digest: manifest.manifest_digest, window_starts_at: window_start, window_ends_at: window_end)
    assert denied.denied?
    assert_equal :no_entitlement, denied.reason
    assert_equal 0, RecordingStudioBilling::MeterAggregation.count

    missing = with_entitlement do
      RecordingStudioBilling.rate_usage(root_recording: root, meter_recording: SecureRandom.uuid,
                                        manifest_digest: manifest.manifest_digest, window_starts_at: window_start, window_ends_at: window_end)
    end
    assert missing.unsupported?
    assert_equal :missing_meter_authority, missing.reason

    ambiguous_manifest, ambiguous_meter = used_manifest(root:, mode: "sum", extra_rate: true)
    usage_events(root, account, "meter_sum", [3])
    ambiguous = with_entitlement do
      RecordingStudioBilling.rate_usage(root_recording: root, meter_recording: ambiguous_meter,
                                        manifest_digest: ambiguous_manifest.manifest_digest, window_starts_at: window_start, window_ends_at: window_end)
    end
    assert ambiguous.unsupported?, ambiguous.inspect
    assert_equal :ambiguous_rate_terms, ambiguous.reason

    fractional_manifest, fractional_meter = used_manifest(root:, mode: "sum", denominator: 2)
    usage_events(root, account, "meter_sum", [3])
    fractional = with_entitlement do
      RecordingStudioBilling.rate_usage(root_recording: root, meter_recording: fractional_meter,
                                        manifest_digest: fractional_manifest.manifest_digest, window_starts_at: window_start, window_ends_at: window_end)
    end
    assert fractional.unsupported?
    assert_equal :invalid_rate_terms, fractional.reason
    assert_equal 0,
                 RecordingStudioBilling::MeterAggregation.where(manifest_digest: fractional_manifest.manifest_digest).count
  end

  test "uses frozen manifest terms and never creates financial commands" do
    root, account = account_authority
    manifest, meter_id = used_manifest(root:, mode: "sum")
    usage_events(root, account, "meter_sum", [6])

    result = with_entitlement do
      RecordingStudioBilling.rate_usage(root_recording: root, meter_recording: meter_id,
                                        manifest_digest: manifest.manifest_digest, window_starts_at: window_start, window_ends_at: window_end)
    end

    assert result.created?
    assert_nil result.rated_usage.customer_amount_minor
    assert_equal 18, result.rated_usage.cost_amount_minor
    assert_equal manifest.canonical_data.fetch("usage_rating").fetch("rates").values.sole,
                 result.rated_usage.rate_snapshot.fetch("rate")
    assert_equal 0, RecordingStudioBilling::FinancialCommand.count
  end

  test "rates from a published resolver manifest after live catalogue terms change" do
    root, account = account_authority
    manifest, meter_recording, rate_recording = published_rating_manifest
    usage_events(root, account, "published_meter", [4])

    catalogue_root = rate_recording.root_recording
    catalogue_root.revise(rate_recording) { |revision| revision.conversion_numerator = 2 }
    assert_equal 2, rate_recording.reload.recordable.conversion_numerator

    result = with_entitlement do
      RecordingStudioBilling.rate_usage(root_recording: root, meter_recording:, manifest_digest: manifest.manifest_digest,
                                        window_starts_at: window_start, window_ends_at: window_end)
    end

    assert result.created?
    assert_equal 4, result.rated_usage.quantity
    assert_nil result.rated_usage.customer_amount_minor
    assert_equal 12, result.rated_usage.cost_amount_minor
    assert_equal 1, result.rated_usage.rate_snapshot.dig("rate", "conversion_numerator")
  end

  test "database triggers reject forged sources and append-only mutations" do
    root, account = account_authority
    manifest, meter_id = used_manifest(root:, mode: "sum")
    usage_events(root, account, "meter_sum", [2])
    result = with_entitlement do
      RecordingStudioBilling.rate_usage(root_recording: root, meter_recording: meter_id,
                                        manifest_digest: manifest.manifest_digest, window_starts_at: window_start, window_ends_at: window_end)
    end
    other_root, other_account = account_authority

    cross_root = with_entitlement do
      RecordingStudioBilling.rate_usage(root_recording: other_root, meter_recording: meter_id,
                                        manifest_digest: manifest.manifest_digest, window_starts_at: window_start, window_ends_at: window_end)
    end
    assert cross_root.denied?
    assert_equal :no_usage, cross_root.reason
    assert_equal 1, RecordingStudioBilling::MeterAggregation.count

    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::MeterAggregation.insert_all!([result.aggregation.attributes.slice("id", "account_recording_id", "meter_recording_id", "usage_unit_recording_id", "manifest_digest", "aggregation", "window_starts_at", "window_ends_at", "aggregated_at", "quantity", "event_count", "input_digest", "input_snapshot", "safe_metadata", "created_at", "updated_at").merge(
        "id" => SecureRandom.uuid, "root_recording_id" => other_root.id, "account_recording_id" => other_account.recording.id
      )])
    end
    forged_aggregation = result.aggregation.attributes.slice("root_recording_id", "account_recording_id",
                                                             "meter_recording_id", "usage_unit_recording_id", "manifest_digest", "aggregation", "window_starts_at", "window_ends_at", "aggregated_at", "quantity", "event_count", "usage_event_ids", "input_digest", "input_snapshot", "safe_metadata", "created_at", "updated_at")
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::MeterAggregation.insert_all!([forged_aggregation.merge("id" => SecureRandom.uuid,
                                                                                     "quantity" => 99)])
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::MeterAggregation.insert_all!([forged_aggregation.merge("id" => SecureRandom.uuid,
                                                                                     "usage_event_ids" => [])])
    end
    forged_rating = result.rated_usage.attributes.slice("root_recording_id", "account_recording_id",
                                                        "meter_aggregation_id", "manifest_digest", "rate_recording_id", "customer_price_recording_id", "cost_rate_recording_id", "rate_card_recording_id", "cost_card_recording_id", "quantity", "customer_amount_minor", "customer_currency_code", "customer_currency_exponent", "cost_amount_minor", "cost_currency_code", "cost_currency_exponent", "window_starts_at", "window_ends_at", "rated_at", "aggregation_snapshot", "rate_snapshot", "safe_metadata", "created_at", "updated_at")
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::RatedUsage.insert_all!([forged_rating.merge("id" => SecureRandom.uuid,
                                                                          "customer_amount_minor" => 99)])
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::RatedUsage.insert_all!([forged_rating.merge("id" => SecureRandom.uuid,
                                                                          "rate_recording_id" => SecureRandom.uuid)])
    end
    assert_raises(ActiveRecord::StatementInvalid) { result.aggregation.update_column(:quantity, 99) }
    assert_raises(ActiveRecord::StatementInvalid) { result.rated_usage.update_column(:customer_amount_minor, 99) }
  end

  private

  def clear_data!
    BillingTestDatabaseCleanup.clear!
  end

  def acquire_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(1_208_120_201)")
  end

  def release_database_lock!
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(1_208_120_201)")
  end

  def account_authority
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Usage #{SecureRandom.hex(4)}"))
    account = RecordingStudioBilling.ensure_account(root_recording: root, name: "Billing")
    [root, account]
  end

  def used_manifest(root:, mode:, extra_rate: false, denominator: 1)
    meter_id = SecureRandom.uuid
    unit_id = SecureRandom.uuid
    rate_card_id = SecureRandom.uuid
    cost_card_id = SecureRandom.uuid
    rate_id = SecureRandom.uuid
    customer_price_id = SecureRandom.uuid
    cost_rate_id = SecureRandom.uuid
    rate = { "rate_recording_id" => rate_id, "key" => "conversion", "rate_card_recording_id" => rate_card_id,
             "usage_unit_recording_id" => unit_id, "conversion_numerator" => 1, "conversion_denominator" => denominator, "conversion_decimal" => nil }
    canonical_data = {
      "usage_rating" => {
        "meters" => { meter_id => { "meter_recording_id" => meter_id, "key" => "meter_#{mode}",
                                    "usage_key" => "meter_#{mode}", "usage_unit_recording_id" => unit_id, "aggregation" => mode } },
        "rate_cards" => { rate_card_id => { "key" => "customer" } },
        "rates" => { rate_id => rate }.tap do |rates|
          if extra_rate
            rates[SecureRandom.uuid] =
              rate.merge("rate_recording_id" => SecureRandom.uuid, "key" => "other")
          end
        end,
        "cost_cards" => { cost_card_id => { "key" => "internal" } },
        "cost_rates" => { cost_rate_id => { "cost_rate_recording_id" => cost_rate_id, "key" => "cost",
                                            "cost_card_recording_id" => cost_card_id, "usage_unit_recording_id" => unit_id, "amount_minor" => 3, "currency_code" => "USD", "currency_exponent" => 2 } },
        "customer_rates" => { customer_price_id => { "customer_price_recording_id" => customer_price_id,
                                                     "key" => "customer", "usage_unit_recording_id" => unit_id, "amount_minor" => 2, "currency_code" => "USD", "currency_exponent" => 2, "pricing_model" => "per_unit", "package_size" => nil, "version" => 1, "scope" => "market" } }
      }
    }
    snapshots = [{ "fixture" => true }]
    references = { "fixture" => { "fixture" => true } }
    envelope = { "schema_version" => "v1", "resolver_version" => "v1", "root_recording_id" => root.id,
                 "canonical_data" => canonical_data, "recording_snapshots" => snapshots, "snapshot_references" => references }
    manifest = RecordingStudioBilling::CommercialManifest.create!(root_recording_id: root.id, schema_version: "v1",
                                                                  resolver_version: "v1", manifest_digest: RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope), canonical_data:, recording_snapshots: snapshots, snapshot_references: references)
    manifest.mark_used!
    [manifest, meter_id]
  end

  def published_rating_manifest
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
    actor = User.create!(email: "publisher-#{SecureRandom.hex(4)}@example.com", password: "Password1!",
                         password_confirmation: "Password1!")
    catalogue_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Catalogue #{SecureRandom.hex(4)}"))
    billing_admin = RecordingStudioBilling.ensure_billing_admin(root_recording: catalogue_root, key: "billing")
    provider = record_catalogue(
      RecordingStudioBilling::ProviderAccount.new(billing_admin_recording: billing_admin.recording, key: "provider",
                                                  adapter_key: "test", name: "Provider", environment: "production", configuration: {}, capabilities: [], supported_markets: ["US"], supported_currencies: ["USD"]), catalogue_root, billing_admin.recording
    )
    market = record_catalogue(
      RecordingStudioBilling::Market.new(provider_account_recording: provider, key: "us", country_codes: ["US"],
                                         country_groups: {}, regional_country_codes: [], global_fallback: false, allowed_currency_codes: ["USD"], default_currency_code: "USD", priority: 1, specificity: 1, ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive", verification_policy: "none"), catalogue_root, billing_admin.recording
    )
    product = record_catalogue(
      RecordingStudioBilling::Product.new(provider_account_recording: provider, key: "usage", kind: "service",
                                          feature_values: {}), catalogue_root, billing_admin.recording
    )
    option = record_catalogue(
      RecordingStudioBilling::BillingOption.new(product_recording: product, key: "usage", recurrence: "one_time",
                                                quantity_mode: "fixed", default_quantity: 1, pricing_model: "per_unit", collection_method: "automatic", payment_terms_days: 0, trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"), catalogue_root, product
    )
    price = record_catalogue(
      RecordingStudioBilling::Price.new(billing_option_recording: option, market_recording: market, key: "base",
                                        amount_minor: 1, currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "market"), catalogue_root, option
    )
    unit = record_catalogue(RecordingStudioBilling::UsageUnit.new(provider_account_recording: provider, key: "unit"),
                            catalogue_root, billing_admin.recording)
    record_catalogue(
      RecordingStudioBilling::OveragePrice.new(billing_option_recording: option, market_recording: market,
                                               usage_unit_recording: unit, key: "overage", amount_minor: 2, currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "market"), catalogue_root, option
    )
    meter = record_catalogue(
      RecordingStudioBilling::Meter.new(usage_unit_recording: unit, key: "published_meter",
                                        aggregation: "sum"), catalogue_root, billing_admin.recording
    )
    rate_card = record_catalogue(
      RecordingStudioBilling::RateCard.new(provider_account_recording: provider,
                                           key: "rates"), catalogue_root, billing_admin.recording
    )
    rate = record_catalogue(
      RecordingStudioBilling::Rate.new(rate_card_recording: rate_card, usage_unit_recording: unit, key: "conversion",
                                       conversion_numerator: 1, conversion_denominator: 1), catalogue_root, rate_card
    )
    cost_card = record_catalogue(
      RecordingStudioBilling::CostCard.new(provider_account_recording: provider,
                                           key: "costs"), catalogue_root, billing_admin.recording
    )
    record_catalogue(
      RecordingStudioBilling::CostRate.new(cost_card_recording: cost_card, usage_unit_recording: unit, key: "cost",
                                           amount_minor: 3, currency_code: "USD", currency_exponent: 2), catalogue_root, cost_card
    )
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(root_recording: catalogue_root,
                                                                     price_recording_ids: [price.id], actor:)
    [RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: candidate.manifest_digests.sole), meter, rate]
  end

  def record_catalogue(recordable, root, parent)
    RecordingStudio.record!(action: "created", recordable:, root_recording: root, parent_recording: parent).recording
  end

  def usage_events(root, account, key, quantities)
    quantities.each_with_index do |quantity, index|
      RecordingStudioBilling::UsageEvent.create!(root_recording: root, account_recording: account.recording,
                                                 usage_key: key, feature_key: key, quantity:, occurred_at: window_start + index.seconds, idempotency_key: "#{key}-#{SecureRandom.uuid}", safe_metadata: {})
    end
  end

  def with_entitlement(&)
    access = Struct.new(:allowed) { def has_feature?(_key) = allowed }.new(true)
    RecordingStudioBilling::EntitlementAccess.stub(:for, access, &)
  end

  def window_start = Time.utc(2026, 8, 12, 12)
  def window_end = window_start + 1.hour
end
