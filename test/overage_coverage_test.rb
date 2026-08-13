# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class OverageCoverageTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup { BillingTestDatabaseCleanup.clear! }
  teardown { BillingTestDatabaseCleanup.clear! }

  test "persists a 3,400-unit package overage once" do
    allocation = persisted_allocation(quantity: 3_400)
    rate = { "amount_minor" => 200, "package_size" => 1_000, "currency_code" => "USD", "currency_exponent" => 2 }

    first = RecordingStudioBilling.calculate_overage(allocation:, rate:)
    second = RecordingStudioBilling.calculate_overage(allocation:, rate: rate.merge("amount_minor" => 999))

    assert_equal first.id, second.id
    assert_equal allocation.id, first.usage_allocation_id
    assert_equal 3_400, first.excess_quantity
    assert_equal 680, first.amount_minor
    assert_equal rate, first.rate_snapshot
  end

  test "rejects a non-positive package size without persisting a calculation" do
    allocation = persisted_allocation(quantity: 1)

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling.calculate_overage(
        allocation:, rate: { "amount_minor" => 1, "package_size" => 0, "currency_code" => "USD",
                             "currency_exponent" => 2 }
      )
    end

    assert_equal "overage package size must be positive", error.message
    assert_nil allocation.reload.overage_calculation
  end

  private

  def persisted_allocation(quantity:)
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Overage #{SecureRandom.hex(4)}"))
    RecordingStudioBilling.ensure_account(root_recording: root, name: "Billing")
    starts_at = 1.hour.ago.change(min: 0, sec: 0)
    ends_at = starts_at + 1.hour
    meter_id = SecureRandom.uuid
    unit_id = SecureRandom.uuid
    rate_card_id = SecureRandom.uuid
    rate_id = SecureRandom.uuid
    price_id = SecureRandom.uuid
    canonical_data = {
      "usage_rating" => {
        "meters" => { meter_id => { "meter_recording_id" => meter_id, "usage_unit_recording_id" => unit_id, "aggregation" => "sum", "usage_key" => "overage" } },
        "rate_cards" => { rate_card_id => { "key" => "rates" } },
        "rates" => { rate_id => { "rate_recording_id" => rate_id, "rate_card_recording_id" => rate_card_id, "usage_unit_recording_id" => unit_id, "conversion_numerator" => 1, "conversion_denominator" => 1, "conversion_decimal" => nil } },
        "cost_cards" => {}, "cost_rates" => {},
        "customer_rates" => { price_id => { "customer_price_recording_id" => price_id, "usage_unit_recording_id" => unit_id, "amount_minor" => 2, "currency_code" => "USD", "currency_exponent" => 2, "pricing_model" => "per_unit", "package_size" => nil } }
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
      RecordingStudioBilling.record_usage(root_recording: root, usage_key: "overage", quantity:,
                                          idempotency_key: SecureRandom.uuid, occurred_at: starts_at + 1.minute)
      RecordingStudioBilling.rate_usage(root_recording: root, meter_recording: meter_id,
                                        manifest_digest: manifest.manifest_digest, window_starts_at: starts_at, window_ends_at: ends_at).rated_usage
    end

    RecordingStudioBilling.allocate_rated_usage(rated_usage:).allocation
  end
end
