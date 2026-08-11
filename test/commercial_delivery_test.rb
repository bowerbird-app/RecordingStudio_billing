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
    @publication_actor = User.create!(
      email: "billing-publisher-#{SecureRandom.hex(4)}@example.com",
      password: "Password1!",
      password_confirmation: "Password1!"
    )
    RecordingStudioBilling.configuration.feature_definitions = {
      "projects" => {
        source: "catalogue", merge_rule: "replace", default: 1, type: "limit",
        meter_key: nil, usage_unit_key: nil, replenishment: "none", lifecycle: "subscription",
        consumption: "none", ordering: 1, validation: { "minimum" => 0 }
      },
      "enabled" => {
        source: "catalogue", merge_rule: "replace", default: true, type: "boolean",
        meter_key: nil, usage_unit_key: nil, replenishment: "none", lifecycle: "subscription",
        consumption: "none", ordering: 2, validation: {}
      }
    }
    RecordingStudioBilling.configuration.tax_policy = {}
    RecordingStudioBilling.configuration.market_default_country = nil
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
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
    assert_raises(RecordingStudioBilling::CommercialManifestCanonicalizer::UnsupportedValue) do
      RecordingStudioBilling::CommercialManifestCanonicalizer.canonicalize("a" => 1, a: 2)
    end
    assert_raises(RecordingStudioBilling::CommercialManifestCanonicalizer::UnsupportedValue) do
      RecordingStudioBilling::CommercialManifestCanonicalizer.canonicalize("__time__" => "client value")
    end
    nested = "leaf"
    34.times { nested = [nested] }
    assert_raises(RecordingStudioBilling::CommercialManifestCanonicalizer::UnsupportedValue) do
      RecordingStudioBilling::CommercialManifestCanonicalizer.canonicalize(nested)
    end

    data = JSON.parse(RecordingStudioBilling::CommercialManifestCanonicalizer.canonicalize("price" => 100))
    snapshots = [{ "recording_id" => SecureRandom.uuid }]
    references = { "recording" => {} }
    root = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Manifest root")))
    envelope = {
      "schema_version" => "v1", "resolver_version" => "v1", "root_recording_id" => root.id,
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
      root_recording_id: root.id, schema_version: "v2", resolver_version: "v1",
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
      root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id],
      actor: publication_actor
    )
    assert_predicate candidate, :activated?
    assert RecordingStudioBilling::Price.where(state: "published").exists?
    assert RecordingStudioBilling::CommercialManifest.where(used_at: ..Time.current).exists?
    publication_events = RecordingStudio::Event.where(action: "commercial_published")
    assert publication_events.exists?
    assert(publication_events.all? { |event| event.actor == publication_actor })
    revision_events = RecordingStudio::Event.where(
      "metadata ->> 'commercial_candidate_digest' = ?",
      candidate.candidate_digest
    )
    assert revision_events.exists?
    assert(revision_events.all? { |event| event.actor == publication_actor })
    assert_raises(ActiveRecord::RecordInvalid) do
      RecordingStudioBilling::Price.find_by!(state: "published").update!(amount_minor: 999)
    end
  end

  test "an invalid graph rolls back every publication artifact" do
    graph = commercial_graph
    RecordingStudioBilling.configuration.feature_definitions = {}

    assert_raises(KeyError) do
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id],
        actor: publication_actor
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
      root_recording: graph[:root], effective_at:, price_recording_ids: selection, actor: publication_actor
    )
    second = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at:, price_recording_ids: selection, actor: publication_actor
    )

    assert_equal first.id, second.id
    assert_equal "draft", graph[:germany_price].reload.state
    assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root], effective_at:, price_recording_ids: [graph[:germany_price].recording.id],
        actor: publication_actor
      )
    end
  end

  test "activated publication retries return the matching candidate without duplicate artifacts" do
    graph = commercial_graph
    effective_at = Time.current.change(usec: 0)
    selection = [graph[:italy_price].recording.id]

    first = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      effective_at:,
      price_recording_ids: selection,
      actor: publication_actor
    )
    event_count = RecordingStudio::Event.where(action: "commercial_published").count
    manifest_count = RecordingStudioBilling::CommercialManifest.count

    same_time_retry = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      effective_at:,
      price_recording_ids: selection,
      actor: publication_actor
    )
    immediate_retry = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      price_recording_ids: selection,
      actor: publication_actor
    )

    assert_equal first.id, same_time_retry.id
    assert_equal first.id, immediate_retry.id
    assert_equal event_count, RecordingStudio::Event.where(action: "commercial_published").count
    assert_equal manifest_count, RecordingStudioBilling::CommercialManifest.count
  end

  test "candidate and manifest envelope tampering is rejected by the database" do
    graph = commercial_graph
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at: 2.minutes.from_now,
      price_recording_ids: [graph[:italy_price].recording.id], actor: publication_actor
    )
    manifest = RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: candidate.manifest_digests.first)
    assert_raises(ActiveRecord::StatementInvalid) do
      manifest.update_column(:canonical_data, manifest.canonical_data.merge("tampered" => true))
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      candidate.update_column(:effective_at, 1.minute.ago)
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

  test "provider configuration is public allowlisted metadata only" do
    provider = RecordingStudioBilling::ProviderAccount.new(
      billing_admin_recording_id: SecureRandom.uuid, key: "invalid_provider_configuration", adapter_key: "stripe",
      name: "Provider", environment: "production", configuration: { "provider_account_id" => "internal" },
      capabilities: [], supported_markets: [], supported_currencies: []
    )

    assert_not provider.valid?
    assert_includes provider.errors[:configuration], "contains unsupported keys: provider_account_id"

    provider.configuration = {}
    provider.valid?
    assert_empty provider.errors[:configuration]
  end

  test "publication requires an actor and an authorizer" do
    graph = commercial_graph
    RecordingStudioBilling.configuration.instance_variable_set(:@commercial_authorizer, nil)

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id],
        actor: publication_actor
      )
    end
    assert_match(/authorizer/, error.message)

    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { false }
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id],
        actor: publication_actor
      )
    end
    assert_match(/authorized/, error.message)

    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root],
        price_recording_ids: [graph[:italy_price].recording.id],
        actor: nil
      )
    end
    assert_match(/actor/, error.message)

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root],
        price_recording_ids: [graph[:italy_price].recording.id],
        actor: User.new
      )
    end
    assert_match(/persisted/, error.message)
  end

  test "direct commercial revisions cannot publish without the publisher authorization path" do
    graph = commercial_graph
    refute RecordingStudioBilling.respond_to?(:with_commercial_publication)
    assert_raises(NoMethodError) { RecordingStudioBilling.with_commercial_publication { nil } }

    error = assert_raises(ActiveRecord::RecordInvalid) do
      graph[:italy_price].recording.root_recording.revise(graph[:italy_price].recording) do |revision|
        revision.state = "published"
      end
    end

    assert_includes error.record.errors[:state], "may only change through an authorized commercial publication"
    assert_equal "draft", graph[:italy_price].reload.state

    direct_publication = RecordingStudioBilling::Price.new(
      billing_option_recording: graph[:option].recording,
      market_recording: graph[:italy_market].recording,
      key: "direct_publication_price",
      amount_minor: 1_000,
      currency_code: "EUR",
      currency_exponent: 2,
      pricing_model: "flat",
      version: 1,
      scope: "direct",
      state: "published"
    )
    assert_not_predicate direct_publication, :valid?
    assert_includes direct_publication.errors[:state], "may only change through an authorized commercial publication"
  end

  test "reflection and isolated execution state cannot authorize publication" do
    graph = commercial_graph
    assert_raises(NoMethodError) { RecordingStudioBilling.send(:commercial_publication_capability) }
    assert_raises(NoMethodError) { RecordingStudioBilling.send(:with_commercial_publication, Object.new) { nil } }

    ActiveSupport::IsolatedExecutionState[:recording_studio_billing_commercial_publication] = true
    assert_raises(ActiveRecord::RecordInvalid) do
      graph[:italy_price].recording.root_recording.revise(graph[:italy_price].recording) do |revision|
        revision.state = "published"
      end
    end

    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at: 1.minute.from_now,
      price_recording_ids: [graph[:italy_price].recording.id], actor: publication_actor
    )
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { false }
    publisher = RecordingStudioBilling::CommercialPublisher.new(candidate:, actor: publication_actor, now: 2.minutes.from_now)
    error = assert_raises(ArgumentError) { publisher.send(:activate_candidate!, candidate) }
    assert_match(/authorized/, error.message)
    assert_not_predicate candidate.reload, :activated?
  ensure
    ActiveSupport::IsolatedExecutionState.delete(:recording_studio_billing_commercial_publication)
  end

  test "postgresql rejects direct non-draft inserts and state transitions" do
    graph = commercial_graph
    attributes = graph[:italy_price].attributes.except("id", "created_at", "updated_at")
    attributes.merge!("id" => SecureRandom.uuid, "key" => "direct_insert", "state" => "published")

    assert_raises(ActiveRecord::StatementInvalid) { RecordingStudioBilling::Price.insert_all!([attributes]) }
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Price.transaction do
        ActiveRecord::Base.connection.execute(
          "SET LOCAL recording_studio_billing.authorized_publication = 'on'"
        )
        RecordingStudioBilling::Price.insert_all!([
          attributes.merge("id" => SecureRandom.uuid, "key" => "spoofed_direct_insert")
        ])
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Price.where(id: graph[:italy_price].id).update_all(state: "published")
    end

    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id], actor: publication_actor
    )
    published = RecordingStudioBilling::Price.find_by!(state: "published")
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Price.where(id: published.id).update_all(state: "retired")
    end
  end

  test "failure after manifest and candidate persistence rolls back both" do
    graph = commercial_graph

    with_publication_failure(:candidate) do
      assert_raises(ActiveRecord::StatementInvalid) do
        RecordingStudioBilling::CommercialPublisher.publish!(
          root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id], actor: publication_actor
        )
      end
    end

    assert_empty RecordingStudioBilling::CommercialManifest.all
    assert_empty RecordingStudioBilling::CommercialPublicationCandidate.all
    assert_empty RecordingStudioBilling::Price.where(state: "published")
  end

  test "revision activation and event failures roll back every publication artifact" do
    %i[revision activation event].each do |stage|
      graph = commercial_graph
      before = publication_artifact_counts

      with_publication_failure(stage) do
        assert_raises(ActiveRecord::StatementInvalid) do
          RecordingStudioBilling::CommercialPublisher.publish!(
            root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id],
            actor: publication_actor
          )
        end
      end

      assert_equal before, publication_artifact_counts, "#{stage} failure left publication artifacts"
      assert_equal "draft", graph[:italy_price].recording.reload.recordable.state
      reset_publication_test_data!
    end
  end

  test "publishes a new draft using unchanged published dependencies" do
    graph = commercial_graph
    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      price_recording_ids: [graph[:italy_price].recording.id],
      actor: publication_actor
    )

    provider = RecordingStudioBilling::ProviderAccount.with_current_recording.find_by!(key: graph[:provider].key)
    market = RecordingStudioBilling::Market.with_current_recording.find_by!(key: graph[:italy_market].key)
    product = RecordingStudioBilling::Product.with_current_recording.find_by!(key: graph[:product].key)
    option = RecordingStudioBilling::BillingOption.with_current_recording.find_by!(key: graph[:option].key)
    assert_equal %w[published published published published], [provider, market, product, option].map(&:state)
    assert [provider, market, product, option].all?(&:valid?)

    additional_price = price("additional", option.recording, market.recording, 1_100, graph[:root], scope: "additional")
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      price_recording_ids: [additional_price.id],
      actor: publication_actor
    )

    assert_predicate candidate, :activated?
    assert_equal "published", additional_price.reload.recordable.state
  end

  test "publication restores its deferred authorization proof inside an ambient transaction" do
    graph = commercial_graph

    candidate = RecordingStudioBilling::CommercialPublicationCandidate.transaction do
      ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id],
        actor: publication_actor
      )
    end

    assert_predicate candidate, :activated?
    assert_equal "published", graph[:italy_price].recording.reload.recordable.state
  end

  test "publication does not defer an unrelated host constraint" do
    graph = commercial_graph
    connection = ActiveRecord::Base.connection
    suffix = SecureRandom.hex(4)
    parent_table = "host_constraint_parents_#{suffix}"
    child_table = "host_constraint_children_#{suffix}"
    constraint = "host_constraint_#{suffix}"
    connection.execute("CREATE TEMP TABLE #{parent_table} (id uuid PRIMARY KEY)")
    connection.execute("CREATE TEMP TABLE #{child_table} (parent_id uuid)")
    connection.execute(<<~SQL)
      ALTER TABLE #{child_table}
      ADD CONSTRAINT #{constraint}
      FOREIGN KEY (parent_id) REFERENCES #{parent_table}(id)
      DEFERRABLE INITIALLY IMMEDIATE
    SQL
    reached_after_insert = false

    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::CommercialPublicationCandidate.transaction do
        RecordingStudioBilling::CommercialPublisher.publish!(
          root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id],
          actor: publication_actor
        )
        connection.execute("INSERT INTO #{child_table} (parent_id) VALUES ('#{SecureRandom.uuid}')")
        reached_after_insert = true
      end
    end
    refute reached_after_insert
  ensure
    connection&.execute("DROP TABLE IF EXISTS #{child_table}") if child_table
    connection&.execute("DROP TABLE IF EXISTS #{parent_table}") if parent_table
  end

  test "database history guard preserves recordables and delivery artifacts" do
    graph = commercial_graph
    historical_draft_price_id = graph[:italy_price].id
    RecordingStudioBilling::ProviderAccount.where(id: graph[:provider].id).update_all(name: "Updated provider")
    assert_equal "Updated provider", graph[:provider].reload.name
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Price.where(id: historical_draft_price_id).update_all(state: "published")
    end

    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], price_recording_ids: [graph[:italy_price].recording.id],
      actor: publication_actor
    )

    assert_predicate candidate, :activated?
    published_price = RecordingStudioBilling::Price.find_by!(state: "published")
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Price.where(id: historical_draft_price_id).update_all(amount_minor: 999)
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Price.where(id: historical_draft_price_id).delete_all
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::Price.where(id: published_price.id).delete_all
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::CommercialManifest.where(manifest_digest: candidate.manifest_digests.first).delete_all
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::CommercialPublicationCandidate.where(id: candidate.id).delete_all
    end
  end

  test "semantic recording references reject an unexpected recordable type" do
    graph = commercial_graph
    price = RecordingStudioBilling::Price.new(
      billing_option_recording: graph[:italy_market].recording, market_recording: graph[:italy_market].recording,
      key: "wrong_recordable_type", amount_minor: 100, currency_code: "EUR", currency_exponent: 2,
      pricing_model: "flat", version: 1, scope: "default"
    )

    assert_not price.valid?
    assert_includes price.errors[:billing_option_recording], "must reference RecordingStudioBilling::BillingOption"
  end

  test "scheduled activation is idempotent and stale candidates fail closed" do
    graph = commercial_graph
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at: 2.minutes.from_now,
      price_recording_ids: [graph[:italy_price].recording.id], actor: publication_actor
    )
    assert_not_predicate candidate, :activated?
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialPublisher.activate!(candidate: candidate, actor: publication_actor)
    end
    assert_match(/not effective/, error.message)

    RecordingStudioBilling::Price.where(id: graph[:italy_price].id).update_all(amount_minor: 1_001)
    assert_equal 1_001, graph[:italy_price].reload.amount_minor
    travel_to(3.minutes.from_now) do
      error = assert_raises(ArgumentError) do
        RecordingStudioBilling::CommercialPublisher.activate!(candidate: candidate, actor: publication_actor)
      end
      assert_match(/stale or tampered/, error.message)
    end
    assert_equal "draft", graph[:italy_price].recording.reload.recordable.state
  end

  test "scheduled activation is deterministic and does not duplicate events" do
    graph = commercial_graph
    effective_at = 2.minutes.from_now
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      effective_at: effective_at,
      price_recording_ids: [graph[:italy_price].recording.id],
      actor: publication_actor
    )

    travel_to(effective_at + 1.second) do
      RecordingStudioBilling::CommercialPublisher.activate!(candidate: candidate, actor: publication_actor)
      events = RecordingStudio::Event.where(action: "commercial_published").count
      RecordingStudioBilling::CommercialPublisher.activate!(candidate: candidate.reload, actor: publication_actor)
      assert_equal events, RecordingStudio::Event.where(action: "commercial_published").count
    end
  end

  test "price replacement retires the prior recording and selectors ignore historical snapshots" do
    graph = commercial_graph
    prior_recording = graph[:italy_price].recording
    option_recording = graph[:option].recording
    market_recording = graph[:italy_market].recording
    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], price_recording_ids: [prior_recording.id], actor: publication_actor
    )
    prior = prior_recording.reload.recordable
    replacement_recording = record_child(
      RecordingStudioBilling::Price.new(
        billing_option_recording: option_recording,
        market_recording: market_recording,
        key: "italy_eur_price",
        amount_minor: 1_100,
        currency_code: "EUR",
        currency_exponent: 2,
        pricing_model: "flat",
        version: 2,
        scope: "default"
      ),
      graph[:root],
      option_recording
    )

    RecordingStudioBilling::CommercialPublisher.replace_price!(
      prior_price: prior,
      replacement_price: replacement_recording.recordable,
      root_recording: graph[:root],
      actor: publication_actor
    )

    assert_equal "retired", prior_recording.reload.recordable.state
    assert_equal "published", replacement_recording.reload.recordable.state
    assert_predicate prior_recording.recordable, :valid?
    assert_predicate replacement_recording.recordable, :valid?
    selected = RecordingStudioBilling::CommercialPriceSelector.new(
      billing_option: option_recording.reload.recordable,
      market: market_recording.reload.recordable,
      currency_code: "EUR"
    ).price!
    assert_equal replacement_recording.id, selected.recording.id
    assert_equal 1, RecordingStudioBilling::Price.with_current_recording.where(
      billing_option_recording_id: option_recording.id,
      market_recording_id: market_recording.id,
      currency_code: "EUR",
      scope: "default",
      state: "published"
    ).count
    assert_operator RecordingStudioBilling::Price.where(state: "published").count, :>=, 2
  end

  test "overage replacement preserves history and publishes only the replacement" do
    graph = commercial_graph
    usage_unit = record_child(
      RecordingStudioBilling::UsageUnit.new(
        provider_account_recording: graph[:provider].recording,
        key: unique_name("api_call").tr(" ", "_")
      ),
      graph[:root],
      graph[:admin_recording]
    )
    prior_recording = record_child(
      RecordingStudioBilling::OveragePrice.new(
        billing_option_recording: graph[:option].recording,
        market_recording: graph[:italy_market].recording,
        usage_unit_recording: usage_unit,
        key: "italy_api_overage",
        amount_minor: 5,
        currency_code: "EUR",
        currency_exponent: 2,
        pricing_model: "flat",
        version: 1,
        scope: "default"
      ),
      graph[:root],
      graph[:option].recording
    )
    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      price_recording_ids: [graph[:italy_price].recording.id],
      actor: publication_actor
    )
    replacement_recording = record_child(
      RecordingStudioBilling::OveragePrice.new(
        billing_option_recording: graph[:option].recording,
        market_recording: graph[:italy_market].recording,
        usage_unit_recording: usage_unit,
        key: "italy_api_overage",
        amount_minor: 4,
        currency_code: "EUR",
        currency_exponent: 2,
        pricing_model: "flat",
        version: 2,
        scope: "default"
      ),
      graph[:root],
      graph[:option].recording
    )

    candidate = RecordingStudioBilling::CommercialPublisher.replace_overage_price!(
      prior_overage_price: prior_recording.reload.recordable,
      replacement_overage_price: replacement_recording.recordable,
      price_recording_id: graph[:italy_price].recording.id,
      root_recording: graph[:root],
      actor: publication_actor
    )

    assert_equal "retired", prior_recording.reload.recordable.state
    assert_equal "published", replacement_recording.reload.recordable.state
    manifest = RecordingStudioBilling::CommercialManifest.find_by!(
      manifest_digest: candidate.manifest_digests.first
    )
    overage_prices = manifest.canonical_data.fetch("overage_prices")
    overage_amounts = overage_prices.map { |overage| overage.fetch("amount_minor") }
    assert_equal [4], overage_amounts
    assert_includes manifest.snapshot_references, replacement_recording.id
    refute_includes manifest.snapshot_references, prior_recording.id
    assert_equal 1, RecordingStudioBilling::OveragePrice.with_current_recording.where(
      billing_option_recording_id: graph[:option].recording.id,
      market_recording_id: graph[:italy_market].recording.id,
      usage_unit_recording_id: usage_unit.id,
      currency_code: "EUR",
      scope: "default",
      state: "published"
    ).count
  end

  test "publication includes applicable product rules and plan updates in each manifest" do
    graph = commercial_graph
    target = record_child(
      RecordingStudioBilling::Product.new(
        provider_account_recording: graph[:provider].recording,
        key: unique_name("target").tr(" ", "_"),
        kind: "addon"
      ),
      graph[:root],
      graph[:admin_recording]
    )
    target_option = record_child(
      RecordingStudioBilling::BillingOption.new(
        product_recording: target,
        key: unique_name("target_monthly").tr(" ", "_"),
        recurrence: "recurring",
        interval: "month",
        interval_count: 1,
        quantity_mode: "fixed",
        default_quantity: 1,
        pricing_model: "flat",
        collection_method: "automatic",
        payment_terms_days: 0,
        trial_days: 0,
        proration_policy: "none",
        lifecycle_policy: "immediate",
        checkout_policy: "allowed",
        tax_policy: "exclusive"
      ),
      graph[:root],
      target
    )
    target_price = price("target_italy", target_option, graph[:italy_market].recording, 2_000, graph[:root])
    rule = record_child(
      RecordingStudioBilling::ProductRule.new(
        product_recording: graph[:product].recording,
        target_product_recording: target,
        key: unique_name("exclusion").tr(" ", "_"),
        rule_type: "excludes",
        conditions: {}
      ),
      graph[:root],
      graph[:admin_recording]
    )
    plan_update = record_child(
      RecordingStudioBilling::PlanUpdate.new(
        billing_option_recording: graph[:option].recording,
        key: unique_name("plan_update").tr(" ", "_")
      ),
      graph[:root],
      graph[:admin_recording]
    )
    rate_card = record_child(
      RecordingStudioBilling::RateCard.new(
        provider_account_recording: graph[:provider].recording,
        key: unique_name("rate_card").tr(" ", "_")
      ),
      graph[:root],
      graph[:admin_recording]
    )
    cost_card = record_child(
      RecordingStudioBilling::CostCard.new(
        provider_account_recording: graph[:provider].recording,
        key: unique_name("cost_card").tr(" ", "_")
      ),
      graph[:root],
      graph[:admin_recording]
    )

    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      price_recording_ids: [graph[:italy_price].recording.id, target_price.id],
      actor: publication_actor
    )

    assert_equal "published", rule.reload.recordable.state
    assert_equal "published", plan_update.reload.recordable.state
    assert_equal "draft", rate_card.reload.recordable.state
    assert_equal "draft", cost_card.reload.recordable.state
    manifests = RecordingStudioBilling::CommercialManifest.where(
      manifest_digest: RecordingStudioBilling::CommercialPublicationCandidate.last.manifest_digests
    )
    assert_equal 2, manifests.count
    source_manifest = manifests.find do |manifest|
      manifest.canonical_data.dig("product", "key") == graph[:product].key
    end
    target_manifest = manifests.find do |manifest|
      manifest.canonical_data.dig("product", "key") == target.recordable.key
    end
    assert_includes source_manifest.canonical_data.fetch("product_rules").map { |item| item.fetch("key") },
                    rule.recordable.key
    assert_includes source_manifest.canonical_data.fetch("plan_updates").map { |item| item.fetch("key") },
                    plan_update.recordable.key
    assert_includes source_manifest.snapshot_references, rule.id
    assert_includes source_manifest.snapshot_references, plan_update.id
    assert_empty target_manifest.canonical_data.fetch("product_rules")
    assert_empty target_manifest.canonical_data.fetch("plan_updates")
  end

  test "account feature overrides require an authorized actor-attributed revision" do
    graph = commercial_graph
    product_recording = graph[:product].recording
    option_recording = graph[:option].recording
    price_recording = graph[:italy_price].recording
    market_recording = graph[:italy_market].recording
    feature_recording = graph[:enabled_feature].recording
    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      price_recording_ids: [price_recording.id],
      actor: publication_actor
    )
    account_root = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Workspace")))
    account = RecordingStudioBilling.ensure_account(root_recording: account_root, name: "Billing account")
    override_recording = record_child(
      RecordingStudioBilling::FeatureOverride.new(
        account_recording: account.recording,
        feature_recording: feature_recording,
        key: unique_name("enabled_override").tr(" ", "_"),
        value: false
      ),
      account_root,
      account.recording
    )
    assert_predicate override_recording.recordable, :valid?
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FeatureOverride.transaction do
        override_recording.root_recording.revise(override_recording) { |revision| revision.value = true }
        constraint = ActiveRecord::Base.connection.quote_column_name(
          "#{RecordingStudioBilling::FeatureOverride.table_name}_validate_publication"
        )
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS #{constraint} IMMEDIATE")
      end
    end
    assert_equal false, override_recording.reload.recordable.value
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FeatureOverride.transaction do
        override_recording.root_recording.revise(override_recording, actor: publication_actor) do |revision|
          revision.value = true
        end
        constraint = ActiveRecord::Base.connection.quote_column_name(
          "#{RecordingStudioBilling::FeatureOverride.table_name}_validate_publication"
        )
        ActiveRecord::Base.connection.execute("SET CONSTRAINTS #{constraint} IMMEDIATE")
      end
    end
    assert_equal false, override_recording.reload.recordable.value
    assert_raises(ActiveRecord::RecordInvalid) do
      override_recording.root_recording.revise(override_recording) { |revision| revision.state = "published" }
    end
    assert_raises(ArgumentError) do
      RecordingStudioBilling::FeatureOverrideReviser.call(
        recording: override_recording, actor: nil, attributes: { state: "published" }
      )
    end
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { false }
    assert_raises(ArgumentError) do
      RecordingStudioBilling::FeatureOverrideReviser.call(
        recording: override_recording, actor: publication_actor, attributes: { state: "published" }
      )
    end
    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { true }
    RecordingStudioBilling::FeatureOverrideReviser.call(
      recording: override_recording, actor: publication_actor, attributes: { state: "published" }
    )
    revision_event = override_recording.reload.latest_event
    assert_equal "updated", revision_event.action
    assert_equal publication_actor, revision_event.actor

    result = RecordingStudioBilling::CommercialManifestResolver.new(
      product: product_recording.reload.recordable,
      billing_option: option_recording.reload.recordable,
      price: price_recording.reload.recordable,
      market: market_recording.reload.recordable,
      currency_code: "EUR",
      account_recording: account.recording
    ).resolve!

    assert_equal false, result.dig(:canonical_data, "features", "enabled", "value")
  end

  test "due publication activator processes candidates in effective order" do
    base = Time.current.change(usec: 0)
    first_graph = commercial_graph
    second_graph = commercial_graph
    future_graph = commercial_graph
    first = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: first_graph[:root],
      effective_at: base + 1.minute,
      price_recording_ids: [first_graph[:italy_price].recording.id],
      actor: publication_actor
    )
    second = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: second_graph[:root],
      effective_at: base + 2.minutes,
      price_recording_ids: [second_graph[:italy_price].recording.id],
      actor: publication_actor
    )
    future = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: future_graph[:root],
      effective_at: base + 10.minutes,
      price_recording_ids: [future_graph[:italy_price].recording.id],
      actor: publication_actor
    )

    travel_to(base + 3.minutes) do
      activated = RecordingStudioBilling::DueCommercialPublicationActivator.call(
        now: Time.current,
        actor: publication_actor
      )
      assert_equal [first.id, second.id], activated.map(&:id)
      assert_not_predicate future.reload, :activated?
      assert_empty RecordingStudioBilling::DueCommercialPublicationActivator.call(
        now: Time.current,
        actor: publication_actor
      )
    end
  end

  test "due publication activator skips stale candidates and uses its supplied time" do
    base = Time.current.change(usec: 0)
    stale_graph = commercial_graph
    valid_graph = commercial_graph
    stale = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: stale_graph[:root],
      effective_at: base + 1.minute,
      price_recording_ids: [stale_graph[:italy_price].recording.id],
      actor: publication_actor
    )
    valid = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: valid_graph[:root],
      effective_at: base + 2.minutes,
      price_recording_ids: [valid_graph[:italy_price].recording.id],
      actor: publication_actor
    )
    RecordingStudioBilling::Price.where(id: stale_graph[:italy_price].id).update_all(amount_minor: 1_001)
    activation_time = base + 3.minutes

    activated = RecordingStudioBilling::DueCommercialPublicationActivator.call(
      now: activation_time,
      actor: publication_actor
    )

    assert_equal [valid.id], activated.map(&:id)
    assert_not_predicate stale.reload, :activated?
    assert_equal activation_time, valid.reload.activated_at
  end

  test "due publication activator propagates authorization and configuration failures" do
    graph = commercial_graph
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at: 1.minute.from_now,
      price_recording_ids: [graph[:italy_price].recording.id], actor: publication_actor
    )
    now = 2.minutes.from_now

    RecordingStudioBilling.configuration.instance_variable_set(:@commercial_authorizer, nil)
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::DueCommercialPublicationActivator.call(actor: publication_actor, now:)
    end
    assert_match(/authorizer/, error.message)

    RecordingStudioBilling.configuration.commercial_authorizer = ->(**) { false }
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::DueCommercialPublicationActivator.call(actor: publication_actor, now:)
    end
    assert_match(/authorized/, error.message)
    assert_not_predicate candidate.reload, :activated?
  end

  test "concurrent due publication workers claim and report a candidate once" do
    graph = commercial_graph
    candidate = RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root], effective_at: 1.minute.from_now,
      price_recording_ids: [graph[:italy_price].recording.id], actor: publication_actor
    )
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          results << RecordingStudioBilling::DueCommercialPublicationActivator.call(
            actor: publication_actor, now: 2.minutes.from_now
          ).map(&:id)
        end
      rescue StandardError => error
        results << error
      end
    end
    2.times { start << true }
    threads.each(&:join)

    worker_results = 2.times.map { results.pop }
    assert_empty worker_results.grep(Exception)
    assert_equal [candidate.id], worker_results.flatten
    assert_predicate candidate.reload, :activated?
    assert_empty RecordingStudioBilling::DueCommercialPublicationActivator.call(
      actor: publication_actor, now: 2.minutes.from_now
    )
  end

  test "dummy database has every canonical engine migration applied" do
    engine_versions = Dir.glob(File.expand_path("../db/migrate/*.rb", __dir__)).map do |path|
      File.basename(path).split("_", 2).first
    end
    applied_versions = ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations")

    assert_empty engine_versions - applied_versions
  end

  test "market resolution selects distinct Italian and German EUR prices and requotes on finalization" do
    graph = commercial_graph
    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      price_recording_ids: [graph[:italy_price].recording.id, graph[:germany_price].recording.id],
      actor: publication_actor
    )
    italy_market = RecordingStudioBilling::Market.with_current_recording.find_by!(key: "italy_market")
    germany_market = RecordingStudioBilling::Market.with_current_recording.find_by!(key: "germany_market")
    italy_price = RecordingStudioBilling::Price.with_current_recording.find_by!(key: "italy_eur_price")
    germany_price = RecordingStudioBilling::Price.with_current_recording.find_by!(key: "germany_eur_price")
    option = RecordingStudioBilling::BillingOption.with_current_recording.find_by!(key: graph[:option].key)
    resolver = RecordingStudioBilling::MarketResolver.new(markets: [italy_market, germany_market])
    italy = resolver.resolve(stage: :display, declaration_country: "IT", explicit_currency: "EUR")
    germany = resolver.resolve(stage: :display, declaration_country: "DE", explicit_currency: "EUR")

    assert_equal italy_market, italy.market
    assert_equal germany_market, germany.market
    assert_equal italy_price.recording.id, RecordingStudioBilling::CommercialPriceSelector.new(
      billing_option: option, market: italy.market, currency_code: italy.currency_code
    ).price!.recording.id
    assert_equal germany_price.recording.id, RecordingStudioBilling::CommercialPriceSelector.new(
      billing_option: option, market: germany.market, currency_code: germany.currency_code
    ).price!.recording.id
    assert_equal :requote, resolver.resolve(
      stage: :final_charge,
      account_country: RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("DE", :verified_account),
      previous: italy
    ).outcome
    assert_raises(ArgumentError) do
      resolver.resolve(stage: :final_charge, account_country: "DE", previous: italy)
    end
    assert_raises(ArgumentError) do
      resolver.resolve(stage: :final_charge, declaration_country: "IT", ip_country: "DE", previous: italy)
    end
    RecordingStudioBilling.configuration.market_default_country = "IT"
    assert_raises(ArgumentError) { resolver.resolve(stage: :final_charge, previous: italy) }
    assert_equal :provider, resolver.resolve(
      stage: :final_charge,
      provider_country: RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("DE", :provider),
      previous: italy
    ).source
    assert_equal :host, resolver.resolve(
      stage: :final_charge,
      host_country: RecordingStudioBilling::MarketResolver::VerifiedCountryEvidence.new("IT", :host),
      previous: italy
    ).source
    assert_raises(ArgumentError) do
      resolver = RecordingStudioBilling::MarketResolver.new(
        markets: [italy_market, italy_market]
      )
      resolver.resolve(stage: :display, declaration_country: "IT", explicit_currency: "EUR")
    end
  end

  test "market resolution rejects historical market and provider revisions" do
    graph = commercial_graph
    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: graph[:root],
      price_recording_ids: [graph[:italy_price].recording.id],
      actor: publication_actor
    )
    resolver_arguments = { stage: :display, declaration_country: "IT", explicit_currency: "EUR" }

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::MarketResolver.new(markets: [graph[:italy_market]]).resolve(**resolver_arguments)
    end
    assert_match(/no eligible market/, error.message)

    current_market = RecordingStudioBilling::Market.with_current_recording.find_by!(key: "italy_market")
    assert_equal current_market, RecordingStudioBilling::MarketResolver.new(
      markets: [current_market]
    ).resolve(**resolver_arguments).market
  end

  test "product rule conditions skip violations and transitions until they match" do
    source = Struct.new(:recording).new(Struct.new(:id).new("source"))
    target = Struct.new(:recording).new(Struct.new(:id).new("target"))
    conditional_requirement = Struct.new(
      :key, :rule_type, :target_product_recording_id, :conditions
    ).new("us_requires_target", "requires", "target", { "country_code" => "US" })
    conditional_transition = Struct.new(
      :key, :rule_type, :target_product_recording_id, :conditions
    ).new("us_upgrade", "upgrade_from", "target", { "country_code" => "US" })

    unmatched = RecordingStudioBilling::ProductRuleEvaluator.new(
      product: source,
      selected_products: [],
      current_product: target,
      context: { country_code: "CA" },
      rules: [conditional_requirement, conditional_transition]
    ).evaluate
    assert unmatched.eligible
    assert_empty unmatched.violations
    assert_nil unmatched.transition

    matched = RecordingStudioBilling::ProductRuleEvaluator.new(
      product: source,
      selected_products: [],
      current_product: target,
      context: { country_code: "US" },
      rules: [conditional_transition]
    ).evaluate
    assert_equal "upgrade_from", matched.transition
  end

  test "product rule scalar selections use membership and transitions ignore non-transition rules" do
    source = Struct.new(:recording).new(Struct.new(:id).new("source"))
    target = Struct.new(:recording).new(Struct.new(:id).new("target"))
    scalar_requirement = Struct.new(
      :key, :rule_type, :target_product_recording_id, :conditions
    ).new("requires_target", "requires", "target", { "selected_product_recording_ids" => "target" })
    non_transition = Struct.new(
      :key, :rule_type, :target_product_recording_id, :conditions
    ).new("requires_current", "requires", "target", {})
    transition = Struct.new(
      :key, :rule_type, :target_product_recording_id, :conditions
    ).new("upgrade_current", "upgrade_from", "target", {})

    result = RecordingStudioBilling::ProductRuleEvaluator.new(
      product: source,
      selected_products: [target],
      current_product: target,
      rules: [scalar_requirement, non_transition, transition]
    ).evaluate

    assert result.eligible
    assert_equal "upgrade_from", result.transition
  end

  test "commercial manifest resolver rejects injected rules and plan updates from another owner" do
    graph = commercial_graph
    resolver_arguments = {
      product: graph[:product],
      billing_option: graph[:option],
      price: graph[:italy_price],
      market: graph[:italy_market],
      currency_code: "EUR",
      publication_candidate: true
    }

    foreign_rule = RecordingStudioBilling::ProductRule.new(
      product_recording_id: SecureRandom.uuid,
      key: "foreign_rule",
      rule_type: "requires",
      conditions: {}
    )
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialManifestResolver.new(
        **resolver_arguments,
        product_rules: [foreign_rule]
      ).resolve!
    end
    assert_match(/belong to the selected product/, error.message)

    foreign_plan_update = RecordingStudioBilling::PlanUpdate.new(
      billing_option_recording_id: SecureRandom.uuid,
      key: "foreign_plan_update"
    )
    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialManifestResolver.new(
        **resolver_arguments,
        plan_updates: [foreign_plan_update]
      ).resolve!
    end
    assert_match(/belong to the selected billing option/, error.message)
  end

  test "feature definitions fail closed, product rule vocabulary is exact, and tax is off by default" do
    assert_raises(KeyError) { RecordingStudioBilling::FeatureDefinitionRegistry.fetch!("unknown") }
    assert_equal %w[requires excludes available_with replaces upgrade_from downgrade_from same_family],
                 RecordingStudioBilling::ProductRule::RULE_TYPES
    assert_equal false, RecordingStudioBilling.configuration.tax_policy.fetch(:enabled)
    assert_equal "provider_default", RecordingStudioBilling.configuration.tax_policy.fetch(:presentation)
  end

  test "publication rejects a feature whose kind differs from its registered definition" do
    graph = commercial_graph
    definitions = RecordingStudioBilling.configuration.feature_definitions.transform_values(&:dup)
    definitions.fetch("projects")["type"] = "boolean"
    RecordingStudioBilling.configuration.feature_definitions = definitions

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: graph[:root],
        price_recording_ids: [graph[:italy_price].recording.id],
        actor: publication_actor
      )
    end
    assert_match(/feature kind/, error.message)
  end

  private

  attr_reader :publication_actor

  def commercial_graph
    root = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Admin")))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: root, key: unique_name("billing"))
    admin_recording = admin.recording
    provider = record_child(
      RecordingStudioBilling::ProviderAccount.new(
        billing_admin_recording: admin_recording, key: unique_name("provider").tr(" ", "_"),
        adapter_key: "stripe", name: "Provider", environment: "production",
        configuration: { "merchant" => "catalogue" },
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
    enabled_feature = record_child(
      RecordingStudioBilling::Feature.new(
        product_recording: product, key: "enabled", kind: "boolean", definition: {}
      ), root, product
    )
    italy_price = price("italy", option, italy_market, 1_000, root)
    germany_price = price("germany", option, germany_market, 1_200, root)
    {
      root: root, admin_recording: admin_recording,
      product: product.recordable, option: option.recordable, feature: feature.recordable,
      enabled_feature: enabled_feature.recordable,
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

  def price(name, option, market, amount, root, scope: "default")
    record_child(
      RecordingStudioBilling::Price.new(
        billing_option_recording: option, market_recording: market, key: "#{name}_eur_price",
        amount_minor: amount, currency_code: "EUR", currency_exponent: 2, pricing_model: "flat",
        version: 1, scope: scope
      ), root, option
    )
  end

  def record_child(recordable, root, parent)
    event = RecordingStudio.record!(
      action: "created", recordable: recordable, root_recording: root, parent_recording: parent
    )
    RecordingStudio::Recording.unscoped.find(event.recording.id)
  end

  def clear_data!
    RecordingStudio::Event.unscoped.delete_all
    tables = [
      RecordingStudioBilling::CommercialPublicationCandidate.table_name,
      RecordingStudioBilling::CommercialManifest.table_name,
      *RecordingStudioBilling::RECORDABLE_TYPES.map(&:constantize).map(&:table_name)
    ]
    connection = ActiveRecord::Base.connection
    quoted_tables = tables.map { |table| connection.quote_table_name(table) }.join(", ")
    connection.execute("TRUNCATE TABLE #{quoted_tables} RESTART IDENTITY CASCADE")
    RecordingStudio::Recording.unscoped.delete_all
    Workspace.delete_all
    AdminRoot.delete_all
    User.delete_all
  end

  def reset_publication_test_data!
    clear_data!
    @publication_actor = User.create!(
      email: "billing-publisher-#{SecureRandom.hex(4)}@example.com",
      password: "Password1!", password_confirmation: "Password1!"
    )
  end

  def publication_artifact_counts
    {
      manifests: RecordingStudioBilling::CommercialManifest.count,
      candidates: RecordingStudioBilling::CommercialPublicationCandidate.count,
      events: RecordingStudio::Event.unscoped.count,
      recordings: RecordingStudio::Recording.unscoped.count,
      recordables: RecordingStudioBilling::RECORDABLE_TYPES.to_h { |type| [type, type.constantize.count] }
    }
  end

  def with_publication_failure(stage)
    function = "rs_billing_test_fail_#{stage}"
    table, timing, event, condition = case stage
                              when :candidate
                                [RecordingStudioBilling::CommercialPublicationCandidate.table_name, "AFTER", "INSERT", "TRUE"]
                              when :revision
                                [RecordingStudioBilling::Price.table_name, "BEFORE", "INSERT", "NEW.state = 'published'"]
                              when :activation
                                [RecordingStudioBilling::CommercialPublicationCandidate.table_name, "BEFORE", "UPDATE",
                                 "NEW.activated_at IS NOT NULL"]
                              when :event
                                [RecordingStudio::Event.table_name, "BEFORE", "INSERT",
                                 "NEW.action = 'commercial_published'"]
                              end
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL)
      CREATE FUNCTION #{function}() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'injected #{stage} failure';
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER #{function}
      #{timing} #{event} ON #{connection.quote_table_name(table)}
      FOR EACH ROW WHEN (#{condition}) EXECUTE FUNCTION #{function}();
    SQL
    yield
  ensure
    connection&.execute("DROP TRIGGER IF EXISTS #{function} ON #{connection.quote_table_name(table)}") if table
    connection&.execute("DROP FUNCTION IF EXISTS #{function}()")
  end

  def unique_name(prefix)
    "#{prefix}_#{SecureRandom.hex(4)}"
  end
end
