# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class FinancialCommandTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class InspectingAdapter
    attr_reader :called_outside_transaction, :persisted_attempt_state, :validated_request

    def initialize(response:)
      @response = response
    end

    def capabilities
      @capabilities ||= RecordingStudioBilling::ProviderCapabilities.new
    end

    def validate!(request:)
      @validated_request = request
    end

    def call(command:, request:, idempotency_key:)
      @called_outside_transaction = !ActiveRecord::Base.connection.transaction_open?
      @persisted_attempt_state = command.attempts.reload.last&.state
      raise @response if @response.is_a?(Exception)

      raise "missing durable execution inputs" if request.blank? || idempotency_key != command.provider_idempotency_key

      @response
    end
  end

  class CrashingAdapter
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def capabilities
      @capabilities ||= RecordingStudioBilling::ProviderCapabilities.new
    end

    def call(**)
      @calls += 1
      raise RecordingStudioBilling::FinancialCommandExecutor::WorkerCrash, "worker disappeared"
    end
  end

  setup do
    clear_financial_data!
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.configuration.stripe_credential_resolver = nil
  end

  teardown do
    clear_financial_data!
    RecordingStudioBilling.configuration.reset_registries!
    RecordingStudioBilling.configuration.stripe_credential_resolver = nil
  end

  test "creation normalizes descendants and returns existing or conflict by canonical material authority" do
    root, account = account_authority
    attributes = command_attributes(root:, account:, request: { amount_minor: 1_500, currency: "USD", quantity: 2 })

    created = RecordingStudioBilling::CreateFinancialCommand.call(**attributes)
    existing = RecordingStudioBilling::CreateFinancialCommand.call(
      **attributes.merge(root_recording: account.recording, request: { quantity: 2, currency: "USD", amount_minor: 1_500 })
    )
    conflict = RecordingStudioBilling::CreateFinancialCommand.call(
      **attributes.merge(request: attributes.fetch(:request).merge(amount_minor: 1_501))
    )

    assert created.created?
    assert existing.existing?
    assert conflict.conflict?
    assert_equal created.command, existing.command
    assert_equal created.command, conflict.command
    assert_equal root.id, created.command.root_recording_id
    assert_equal account.recording.id, created.command.account_recording_id
    assert_equal "USD", created.command.canonical_request.dig("request", "currency")
    assert_equal "calculator_v1", created.command.canonical_request.dig("authority", "calculator_key")
    assert_match(/\Arsb-[0-9a-f-]{36}\z/, created.command.provider_idempotency_key)
  end

  test "account must belong directly to the normalized root" do
    root, = account_authority
    other_root, other_account = account_authority

    error = assert_raises(ArgumentError) do
      RecordingStudioBilling::CreateFinancialCommand.call(
        **command_attributes(root:, account: other_account, request: { amount_minor: 100 })
      )
    end

    assert_match(/directly/, error.message)
    refute_equal root.id, other_root.id
    assert_equal 0, RecordingStudioBilling::FinancialCommand.count
  end

  test "provider accounts use their BillingAdmin root independently of the customer root" do
    customer_root, account = account_authority
    provider_recording = provider_authority

    result = RecordingStudioBilling.create_financial_command(
      **command_attributes(root: customer_root, account:, request: { amount_minor: 100 })
        .except(:calculator_key, :calculator_mode)
        .merge(provider_account_recording: provider_recording, provider_adapter_key: "test")
    )

    assert result.created?
    refute_equal customer_root.id, provider_recording.root_recording_id
    assert_equal provider_recording.id, result.command.provider_account_recording_id
  end

  test "exactly one safe execution authority is required" do
    root, account = account_authority
    attributes = command_attributes(root:, account:, request: { amount_minor: 100 })

    assert_raises(ArgumentError) do
      RecordingStudioBilling.create_financial_command(**attributes.except(:calculator_key))
    end
    assert_raises(ArgumentError) do
      RecordingStudioBilling.create_financial_command(
        **attributes.merge(provider_account_recording: provider_authority)
      )
    end
    assert_raises(RecordingStudioBilling::SafeFinancialPayload::UnsafeValue) do
      RecordingStudioBilling.create_financial_command(
        **attributes.merge(request: { amount_minor: 100, access_token: "must-not-persist" })
      )
    end
  end

  test "database idempotency serializes concurrent creation on separate connections" do
    root, account = account_authority
    attributes = command_attributes(root:, account:, request: { amount_minor: 2_000 })
    ready = Queue.new
    release = Queue.new
    results = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          results << RecordingStudioBilling::CreateFinancialCommand.call(**attributes)
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)
    statuses = 2.times.map { results.pop.status }.sort

    assert_equal %i[created existing], statuses
    assert_equal 1, RecordingStudioBilling::FinancialCommand.count
  end

  test "concurrent conflicting creation returns one created command and one conflict" do
    root, account = account_authority
    key = "conflict-#{SecureRandom.uuid}"
    ready = Queue.new
    release = Queue.new
    results = Queue.new

    threads = [100, 200].map do |amount|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          results << RecordingStudioBilling.create_financial_command(
            **command_attributes(root:, account:, request: { approved_amount_minor: amount })
              .merge(local_idempotency_key: key)
          )
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)

    assert_equal %i[conflict created], 2.times.map { results.pop.status }.sort
    assert_equal 1, RecordingStudioBilling::FinancialCommand.count
  end

  test "cross-root unused unknown-version and tampered manifests are rejected" do
    root, account = account_authority
    other_root, = account_authority
    cross_root = create_manifest(root: other_root, used: true)
    unused = create_manifest(root:, used: false)
    unknown = insert_manifest(root:, schema_version: "v999", valid_digest: true)
    tampered = insert_manifest(root:, schema_version: "v1", valid_digest: false)

    {
      cross_root.manifest_digest => /another root/,
      unused.manifest_digest => /not published and used/,
      unknown.manifest_digest => /version is unsupported/,
      tampered.manifest_digest => /digest is invalid/
    }.each do |digest, message|
      error = assert_raises(ArgumentError) do
        RecordingStudioBilling.create_financial_command(
          **command_attributes(root:, account:, request: { approved_amount_minor: 100 })
            .merge(commercial_manifest_digests: [digest])
        )
      end
      assert_match message, error.message
    end
  end

  test "executor commits command and initial attempt before calling adapter" do
    root, account = account_authority
    adapter = InspectingAdapter.new(
      response: {
        state: "succeeded", provider_reference: "provider-123",
        normalized_result: { status: "succeeded", amount_minor: 750 }, safe_metadata: { request_id: "public-1" }
      }
    )

    key = register_provider(adapter)
    result = RecordingStudioBilling::FinancialCommandExecutor.call(
      provider_key: key, **provider_command_attributes(root:, account:, request: { amount_minor: 750 })
    )
    command = result.command.reload
    attempt = command.attempts.first

    assert result.created?
    assert adapter.called_outside_transaction
    assert_equal "processing", adapter.persisted_attempt_state
    assert_equal({ amount_minor: 750 }, adapter.validated_request)
    assert_equal "succeeded", command.state
    assert_equal "provider-123", command.provider_reference
    assert_equal "succeeded", attempt.state
    assert_predicate attempt, :completed_at?
  end

  test "two concurrent executors claim once and call the adapter once" do
    root, account = account_authority
    command = RecordingStudioBilling.create_financial_command(
      **provider_command_attributes(root:, account:, request: { approved_amount_minor: 750 })
    ).command
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success)
    register_provider(adapter)
    ready = Queue.new
    release = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          RecordingStudioBilling::FinancialCommandExecutor.execute(
            command: RecordingStudioBilling::FinancialCommand.find(command.id), provider_key: "test"
          )
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:join)

    assert_equal 1, adapter.calls
    assert_equal 1, command.attempts.count
    assert_equal "succeeded", command.reload.state
  end

  test "crash before external call leaves a leased open attempt for expiry" do
    command = pending_command
    now = Time.current
    claim = RecordingStudioBilling::FinancialCommandClaim.call(command:, lease_duration: 1.minute, now:)

    assert_equal "processing", command.reload.state
    assert_equal claim.token, command.claim_token
    assert_nil claim.attempt.completed_at
    assert_equal 1, RecordingStudioBilling.expire_financial_command_claims(now: now + 2.minutes)
    assert_equal "requires_reconciliation", command.reload.state
    assert_equal "uncertain", claim.attempt.reload.state
    assert_predicate claim.attempt, :completed_at?
  end

  test "crash during external call preserves the live lease and open attempt" do
    command = pending_command
    adapter = CrashingAdapter.new
    register_provider(adapter)

    assert_raises(RecordingStudioBilling::FinancialCommandExecutor::WorkerCrash) do
      RecordingStudioBilling::FinancialCommandExecutor.execute(command:, provider_key: "test")
    end

    assert_equal 1, adapter.calls
    assert_equal "processing", command.reload.state
    assert_nil command.attempts.first.completed_at
  end

  test "crash after provider success but before persistence remains recoverable" do
    command = pending_command
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success)
    register_provider(adapter)

    assert_raises(RecordingStudioBilling::FinancialCommandExecutor::WorkerCrash) do
      RecordingStudioBilling::FinancialCommandExecutor.execute(
        command:, provider_key: "test",
        after_adapter_call: ->(*) { raise RecordingStudioBilling::FinancialCommandExecutor::WorkerCrash }
      )
    end

    assert_equal 1, adapter.calls
    assert_equal "processing", command.reload.state
    assert_nil command.provider_reference
    assert_nil command.attempts.first.completed_at
  end

  test "a provider result cannot persist after its lease expires" do
    command = pending_command
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success)
    register_provider(adapter)

    assert_raises(ArgumentError) do
      RecordingStudioBilling::FinancialCommandExecutor.execute(
        command:, provider_key: "test",
        after_adapter_call: lambda do |claimed_command, _response|
          RecordingStudioBilling.expire_financial_command_claims(now: claimed_command.lease_expires_at + 1.second)
        end
      )
    end

    assert_equal "requires_reconciliation", command.reload.state
    assert_nil command.provider_reference
    assert_equal "uncertain", command.attempts.first.state
  end

  test "lease expiry and controlled recovery append attempt two with the original provider key" do
    command = pending_command
    original_key = command.provider_idempotency_key
    now = Time.current
    first_claim = RecordingStudioBilling::FinancialCommandClaim.call(command:, lease_duration: 1.minute, now:)
    RecordingStudioBilling.expire_financial_command_claims(now: now + 2.minutes)
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :duplicate)
    register_provider(adapter)

    RecordingStudioBilling.recover_financial_command(command: command.reload, provider_key: "test")

    attempts = command.attempts.order(:attempt_number).to_a
    assert_equal [1, 2], attempts.map(&:attempt_number)
    assert_equal [original_key, original_key], attempts.map(&:provider_idempotency_key)
    assert_equal [original_key], adapter.idempotency_keys
    assert_equal "uncertain", first_claim.attempt.reload.state
    assert_equal "succeeded", command.reload.state
  end

  test "provider pending cannot replay through ordinary execution and recovers with the original key" do
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :pending)
    command = execute_new_command(adapter:).command.reload
    original_key = command.provider_idempotency_key

    RecordingStudioBilling::FinancialCommandExecutor.execute(command:, provider_key: "test")

    assert_equal 1, adapter.calls
    assert_equal 1, command.attempts.count
    assert_equal "requires_reconciliation", command.reload.state
    assert_equal "pending", command.normalized_result["status"]

    recovery_adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :duplicate)
    register_provider(recovery_adapter)
    RecordingStudioBilling.recover_financial_command(command:, provider_key: "test")

    assert_equal [1, 2], command.attempts.order(:attempt_number).pluck(:attempt_number)
    assert_equal [original_key, original_key], command.attempts.order(:attempt_number).pluck(:provider_idempotency_key)
    assert_equal [original_key], recovery_adapter.idempotency_keys
  end

  test "recovering an ineligible command does not expire unrelated stale work" do
    unrelated = pending_command
    now = 2.minutes.ago
    RecordingStudioBilling::FinancialCommandClaim.call(command: unrelated, lease_duration: 1.minute, now:)
    target = pending_command
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :success)
    register_provider(adapter)

    assert_raises(ArgumentError) do
      RecordingStudioBilling.recover_financial_command(command: target, provider_key: "test")
    end

    assert_equal "processing", unrelated.reload.state
    assert_equal 1, unrelated.attempts.count
    assert_equal "pending", target.reload.state
    assert_empty target.attempts
    assert_equal 0, adapter.calls
  end

  test "recovery rejects an ambient transaction before claiming or calling the adapter" do
    command = pending_command
    now = Time.current
    RecordingStudioBilling::FinancialCommandClaim.call(command:, lease_duration: 1.minute, now:)
    RecordingStudioBilling.expire_financial_command_claims(now: now + 2.minutes)
    adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :duplicate)
    register_provider(adapter)

    RecordingStudioBilling::FinancialCommand.transaction do
      assert_raises(ArgumentError) do
        RecordingStudioBilling.recover_financial_command(command: command.reload, provider_key: "test")
      end
    end

    assert_equal 0, adapter.calls
    assert_equal 1, command.attempts.count
  end

  test "fake adapter outcomes map deterministically including pending and unknown" do
    expectations = {
      success: ["succeeded", "success", "success"],
      duplicate: ["succeeded", "duplicate", "duplicate"],
      provider_rejection: ["failed", "provider_rejected", "provider_rejected"],
      provider_unavailable: ["failed", "provider_unavailable", "provider_unavailable"],
      pending: ["requires_reconciliation", "pending", "pending"],
      unknown_provider_state: ["requires_reconciliation", "unknown", "unknown_provider_state"]
    }

    expectations.each do |outcome, (state, status, normalized_outcome)|
      adapter = RecordingStudioBilling::FakeFinancialAdapter.new(outcome:)
      result = execute_new_command(adapter:)
      command = result.command.reload
      assert_equal state, command.state, outcome
      assert_equal status, command.normalized_result["status"], outcome
      assert_equal normalized_outcome, command.normalized_result["outcome"], outcome
    end

    invalid = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :invalid_request)
    assert_raises(RecordingStudioBilling::FakeFinancialAdapter::InvalidRequest) { execute_new_command(adapter: invalid) }
    timeout = RecordingStudioBilling::FakeFinancialAdapter.new(outcome: :timeout_after_possible_success)
    assert_raises(RecordingStudioBilling::FakeFinancialAdapter::TimeoutAfterPossibleSuccess) do
      execute_new_command(adapter: timeout)
    end
    assert_equal "requires_reconciliation", RecordingStudioBilling::FinancialCommand.order(:created_at).last.state

    processing = InspectingAdapter.new(response: { state: "processing", normalized_result: {} })
    processing_command = execute_new_command(adapter: processing).command.reload
    assert_equal "requires_reconciliation", processing_command.state
    assert_equal "unknown", processing_command.normalized_result["status"]
  end

  test "stripe without host credentials persists a provider-neutral unavailable result" do
    root, account = account_authority
    result = RecordingStudioBilling.execute_financial_command(
      provider_key: :stripe,
      **provider_command_attributes(root:, account:, request: { approved_amount_minor: 500 }, adapter_key: "stripe")
    )
    command = result.command.reload
    attempt = command.attempts.first

    assert_equal "failed", command.state
    assert_equal "provider_unavailable", command.normalized_result.fetch("status")
    assert_equal "configuration_missing", command.normalized_result.fetch("reason")
    assert_equal "failed", attempt.state
    assert_predicate attempt, :completed_at?
    refute_includes [command.normalized_result, command.safe_error_details, attempt.safe_metadata].to_s, "secret"
  end

  test "executor rejects ambient transactions before persistence or adapter calls" do
    root, account = account_authority
    adapter = InspectingAdapter.new(response: { state: "succeeded", normalized_result: {} })

    assert_no_difference -> { RecordingStudioBilling::FinancialCommand.count } do
      RecordingStudioBilling::FinancialCommand.transaction do
        error = assert_raises(ArgumentError) do
          key = register_provider(adapter)
          RecordingStudioBilling.execute_financial_command(
            provider_key: key, **provider_command_attributes(root:, account:, request: { amount_minor: 700 })
          )
        end
        assert_match(/open database transaction/, error.message)
      end
    end
    assert_nil adapter.validated_request
  end

  test "unknown adapter states require reconciliation and remain unknown in normalized results" do
    root, account = account_authority
    adapter = InspectingAdapter.new(response: { state: "provider_reviewing", normalized_result: { status: "provider_reviewing" } })

    key = register_provider(adapter)
    result = RecordingStudioBilling::FinancialCommandExecutor.call(
      provider_key: key, **provider_command_attributes(root:, account:, request: { amount_minor: 800 })
    )
    command = result.command.reload

    assert_equal "requires_reconciliation", command.state
    assert_equal "pending", command.reconciliation_state
    assert_equal "unknown", command.normalized_result.fetch("status")
    assert_predicate command.attempts.first, :uncertain_outcome?
  end

  test "adapter exceptions record only safe uncertainty details after the external boundary" do
    root, account = account_authority
    adapter = InspectingAdapter.new(response: RuntimeError.new("secret response body"))

    assert_raises(RuntimeError) do
      key = register_provider(adapter)
      RecordingStudioBilling::FinancialCommandExecutor.call(
        provider_key: key, **provider_command_attributes(root:, account:, request: { amount_minor: 900 })
      )
    end
    command = RecordingStudioBilling::FinancialCommand.last
    attempt = command.attempts.first

    assert_equal "requires_reconciliation", command.state
    assert_equal({ "error_class" => "RuntimeError" }, command.safe_error_details)
    assert_equal "uncertain", attempt.state
    assert_predicate attempt, :uncertain_outcome?
    refute_includes attempt.safe_error_details.to_s, "secret response body"
  end

  test "attempt payloads reject credentials and completed history is database protected" do
    root, account = account_authority
    command = RecordingStudioBilling::CreateFinancialCommand.call(
      **provider_command_attributes(root:, account:, request: { amount_minor: 1_000 })
    ).command
    unsafe_attempt = command.attempts.new(
      attempt_number: 1, state: "processing", provider_idempotency_key: command.provider_idempotency_key,
      started_at: Time.current, safe_metadata: { nested: [{ access_token: "nope" }] }
    )

    refute unsafe_attempt.valid?
    assert_includes unsafe_attempt.errors[:safe_metadata], "must not contain credentials, signatures, or raw provider data"

    adapter = InspectingAdapter.new(response: { state: "succeeded", normalized_result: { status: "succeeded" } })
    register_provider(adapter)
    RecordingStudioBilling::FinancialCommandExecutor.execute(command:, provider_key: "test")
    completed_attempt = command.attempts.first
    assert_raises(ActiveRecord::StatementInvalid) { completed_attempt.update_column(:state, "failed") }
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommandAttempt.where(id: completed_attempt.id).update_all(id: SecureRandom.uuid)
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommandAttempt.where(id: completed_attempt.id).update_all(created_at: 1.day.ago)
    end
    assert_raises(ActiveRecord::StatementInvalid) { completed_attempt.delete }
  end

  test "database protects command authority and incomplete attempt history" do
    root, account = account_authority
    command = RecordingStudioBilling.create_financial_command(
      **command_attributes(root:, account:, request: { amount_minor: 1_100 })
    ).command

    assert_raises(ActiveRecord::StatementInvalid) do
      command.update_column(:canonical_request, command.canonical_request.merge("tampered" => true))
    end
    assert_raises(ActiveRecord::StatementInvalid) { command.delete }

    attempt = RecordingStudioBilling::FinancialCommandClaim.call(command:).attempt
    assert_raises(ActiveRecord::StatementInvalid) { attempt.update_column(:safe_metadata, { "rewritten" => true }) }
    assert_raises(ActiveRecord::StatementInvalid) do
      command.attempts.insert_all!([{
        id: SecureRandom.uuid, attempt_number: 2, state: "processing",
        provider_idempotency_key: "different-key", started_at: Time.current,
        normalized_result: {}, safe_error_details: {}, safe_metadata: {}, uncertain_outcome: false,
        created_at: Time.current, updated_at: Time.current
      }])
    end
  end

  test "PostgreSQL rejects malformed attempts and invalid Recording ownership" do
    command = pending_command
    base_attempt = {
      id: SecureRandom.uuid, financial_command_id: command.id, attempt_number: 1,
      provider_idempotency_key: command.provider_idempotency_key, started_at: Time.current,
      normalized_result: {}, safe_error_details: {}, safe_metadata: {}, uncertain_outcome: false,
      created_at: Time.current, updated_at: Time.current
    }
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommandAttempt.insert_all!([base_attempt.merge(state: "succeeded")])
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommandAttempt.insert_all!([
        base_attempt.merge(id: SecureRandom.uuid, attempt_number: 99, state: "processing")
      ])
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommandAttempt.insert_all!([
        base_attempt.merge(id: SecureRandom.uuid, state: "processing", completed_at: Time.current)
      ])
    end

    other_root, other_account = account_authority
    malformed = command.attributes.except("id", "created_at", "updated_at").merge(
      "operation_id" => SecureRandom.uuid, "account_recording_id" => other_account.recording.id,
      "local_idempotency_key" => SecureRandom.uuid, "provider_idempotency_key" => "rsb-#{SecureRandom.uuid}"
    )
    refute_equal command.root_recording_id, other_root.id
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommand.insert_all!([malformed])
    end

    provider_recording = provider_authority
    provider_recording.update_column(:parent_recording_id, provider_recording.root_recording_id)
    malformed_provider = command.attributes.except("id", "created_at", "updated_at").merge(
      "operation_id" => SecureRandom.uuid, "provider_account_recording_id" => provider_recording.id,
      "calculator_key" => nil, "local_idempotency_key" => SecureRandom.uuid,
      "provider_idempotency_key" => "rsb-#{SecureRandom.uuid}"
    )
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommand.insert_all!([malformed_provider])
    end
  end

  test "deferred PostgreSQL checks reject command and open-attempt lifecycle mismatches" do
    command = pending_command

    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommand.transaction do
        command.update_columns(
          state: "processing", claim_token: SecureRandom.uuid,
          claimed_at: Time.current, lease_expires_at: 5.minutes.from_now
        )
      end
    end

    command.reload
    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommand.transaction do
        command.attempts.create!(
          attempt_number: 1, state: "processing", provider_idempotency_key: command.provider_idempotency_key,
          started_at: Time.current
        )
      end
    end
  end

  test "a command cannot be claimed after its authority Recording is trashed" do
    command = pending_command
    command.account_recording.update_column(:trashed_at, Time.current)

    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioBilling::FinancialCommandClaim.call(command:)
    end
    assert_equal "pending", command.reload.state
    assert_empty command.attempts
  end

  test "canonical secrets malformed envelopes and fingerprint mismatches are rejected" do
    root, account = account_authority
    safe = command_attributes(
      root:, account:, request: { approved_amount_minor: 1_000, amount_minor: 1_000, currency: "USD" }
    )
    assert RecordingStudioBilling.create_financial_command(**safe).created?
    %i[signature card_number provider_url provider_id provider_payload raw_response total].each do |unsafe_key|
      assert_raises(RecordingStudioBilling::SafeFinancialPayload::UnsafeValue) do
        RecordingStudioBilling.create_financial_command(
          **safe.merge(local_idempotency_key: SecureRandom.uuid, request: { unsafe_key => "unsafe" })
        )
      end
    end

    command = RecordingStudioBilling::FinancialCommand.last
    command.request_fingerprint = "0" * 64
    refute command.valid?
    assert_includes command.errors[:request_fingerprint], "does not match the canonical request"
    command.reload.canonical_request = { "request" => {} }
    refute command.valid?
    assert_includes command.errors[:canonical_request], "has an invalid canonical envelope"
  end

  test "generic domain and command services have no Stripe coupling" do
    indexes = ActiveRecord::Base.connection.indexes(RecordingStudioBilling::FinancialCommand.table_name)
    assert_includes indexes.map(&:name), "idx_rs_billing_commands_pending_work"
    assert_includes indexes.map(&:name), "idx_rs_billing_commands_stale_processing"
    assert_includes indexes.map(&:name), "idx_rs_billing_commands_reconciliation_work"

    generic_service_files = Dir[File.expand_path("../app/services/recording_studio_billing/**/*.rb", __dir__)] -
                            [File.expand_path("../app/services/recording_studio_billing/stripe_adapter.rb", __dir__)]
    generic_service_source = generic_service_files.map { |path| File.read(path) }.join
    refute_match(/Stripe::|stripe_credential_resolver|provider\s*==\s*:stripe/, generic_service_source)
  end

  private

  def account_authority
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Financial root #{SecureRandom.hex(4)}"))
    account = RecordingStudioBilling.ensure_account(root_recording: root, name: "Account #{SecureRandom.hex(4)}")
    [root, account]
  end

  def command_attributes(root:, account:, request:)
    {
      root_recording: root,
      account_recording: account.recording,
      command_type: "capture_funds",
      calculator_key: "calculator_v1",
      calculator_mode: "external_calculation",
      local_idempotency_key: "local-#{SecureRandom.uuid}",
      request:
    }
  end

  def provider_authority(adapter_key: "test")
    root = RecordingStudio.root_recording_for(AdminRoot.create!(name: "Provider root #{SecureRandom.hex(4)}"))
    admin = RecordingStudioBilling.ensure_billing_admin(root_recording: root, key: "admin_#{SecureRandom.hex(4)}")
    provider = RecordingStudioBilling::ProviderAccount.new(
      billing_admin_recording: admin.recording, key: "provider_#{SecureRandom.hex(4)}",
      adapter_key:, name: "Test provider", environment: "test", configuration: {},
      capabilities: [], supported_markets: [], supported_currencies: []
    )
    RecordingStudio.record!(
      action: "created", recordable: provider, root_recording: root, parent_recording: admin.recording
    ).recording
  end

  def pending_command
    root, account = account_authority
    RecordingStudioBilling.create_financial_command(
      **provider_command_attributes(root:, account:, request: { approved_amount_minor: 500 })
    ).command
  end

  def execute_new_command(adapter:)
    root, account = account_authority
    key = register_provider(adapter)
    RecordingStudioBilling.execute_financial_command(
      provider_key: key, **provider_command_attributes(root:, account:, request: { approved_amount_minor: 500 })
    )
  end

  def provider_command_attributes(root:, account:, request:, adapter_key: "test")
    command_attributes(root:, account:, request:).except(:calculator_key, :calculator_mode).merge(
      provider_account_recording: provider_authority(adapter_key:), provider_adapter_key: adapter_key
    )
  end

  def register_provider(adapter, key: "test")
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider(key, adapter)
    key
  end

  def create_manifest(root:, used:)
    data = { "approved_amount_minor" => 500 }
    snapshots = [{ "recording_id" => root.id }]
    references = { "root" => { "recording_id" => root.id } }
    envelope = manifest_envelope(root:, data:, snapshots:, references:)
    RecordingStudioBilling::CommercialManifest.create!(
      root_recording_id: root.id, schema_version: "v1", resolver_version: "v1",
      canonical_data: data, recording_snapshots: snapshots, snapshot_references: references,
      manifest_digest: RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope),
      used_at: used ? Time.current : nil
    )
  end

  def insert_manifest(root:, schema_version:, valid_digest:)
    data = { "approved_amount_minor" => 500 }
    snapshots = [{ "recording_id" => root.id }]
    references = { "root" => { "recording_id" => root.id } }
    envelope = manifest_envelope(root:, data:, snapshots:, references:, schema_version:)
    digest = valid_digest ? RecordingStudioBilling::CommercialManifestCanonicalizer.digest(envelope) : SecureRandom.hex(32)
    RecordingStudioBilling::CommercialManifest.insert_all!([{
      id: SecureRandom.uuid, root_recording_id: root.id, schema_version:, resolver_version: "v1",
      canonical_data: data, recording_snapshots: snapshots, snapshot_references: references,
      manifest_digest: digest, used_at: Time.current, created_at: Time.current, updated_at: Time.current
    }])
    RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: digest)
  end

  def manifest_envelope(root:, data:, snapshots:, references:, schema_version: "v1")
    {
      "schema_version" => schema_version, "resolver_version" => "v1", "root_recording_id" => root.id,
      "canonical_data" => data, "recording_snapshots" => snapshots, "snapshot_references" => references
    }
  end

  def clear_financial_data!
    connection = ActiveRecord::Base.connection
    tables = [RecordingStudioBilling::FinancialCommand.table_name, RecordingStudioBilling::CommercialManifest.table_name]
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