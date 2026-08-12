# frozen_string_literal: true

module RecordingStudioBilling
  class RecordUsage
    Result = Data.define(:status, :event, :reason) do
      def created? = status == :created
      def existing? = status == :existing
      def denied? = status == :denied
    end

    def self.call(...) = new(...).call

    def initialize(root_recording:, usage_key:, quantity:, idempotency_key:, occurred_at: Time.current, metadata: {})
      @root_recording_input = root_recording
      @usage_key = usage_key.to_s
      @quantity = quantity
      @idempotency_key = idempotency_key.to_s
      @occurred_at = occurred_at
      @metadata = metadata
    end

    def call
      root, account = authority!
      attributes = event_attributes(root, account)
      UsageEvent.transaction(requires_new: true) do
        lock_usage_bucket!(root, account)
        existing = UsageEvent.find_by(root_recording: root, idempotency_key:)
        next Result.new(status: :existing, event: existing, reason: nil) if existing

        denial = entitlement_denial(root, account)
        next Result.new(status: :denied, event: nil, reason: denial) if denial

        event = UsageEvent.create!(attributes)
        Result.new(status: :created, event:, reason: nil)
      end
    rescue ActiveRecord::RecordNotUnique
      event = UsageEvent.find_by!(root_recording_id: attributes.fetch(:root_recording_id), idempotency_key:)
      Result.new(status: :existing, event:, reason: nil)
    end

    def authority!
      root = RecordingStudio.root_recording_or_self(root_recording_input)
      RecordingStudio.assert_root_recording!(root)
      root = RecordingStudio::Recording.unscoped.find(root.id)
      account = Account.with_current_recording.find_by!(root_recording: root).recording
      unless account.recordable_type == "RecordingStudioBilling::Account" && account.root_recording_id == root.id &&
             account.parent_recording_id == root.id && account.recordable.root_recording_id == root.id
        raise ArgumentError, "billing account must belong directly to the normalized root"
      end

      [root, account]
    end

    def event_attributes(root, account)
      raise ArgumentError, "usage key is invalid" unless usage_key.match?(/\A[a-z][a-z0-9_:-]*\z/)
      raise ArgumentError, "idempotency key is required" if idempotency_key.empty?
      quantity = Integer(@quantity)
      raise ArgumentError, "quantity must be positive" unless quantity.positive?
      raise ArgumentError, "occurred at is required" unless occurred_at.respond_to?(:to_time)

      {
        root_recording_id: root.id,
        account_recording_id: account.id,
        usage_key:,
        feature_key: usage_key,
        quantity:,
        occurred_at: occurred_at.to_time,
        idempotency_key:,
        safe_metadata: SafeFinancialPayload.normalize(metadata)
      }
    rescue SafeFinancialPayload::UnsafeValue
      raise
    rescue ArgumentError, TypeError
      raise ArgumentError, "quantity must be a positive integer"
    end

    def entitlement_denial(root, account)
      access = EntitlementAccess.for(root_recording: root, account_recording: account, at: occurred_at)
      return :no_entitlement unless access.has_feature?(usage_key)

      limit = access.limit(usage_key)
      allowance = access.allowance(usage_key)
      return :ambiguous_configuration if limit && allowance

      cap = limit || allowance
      return nil unless cap

      total = UsageEvent.where(root_recording: root, account_recording: account, usage_key:).sum(:quantity)
      total + Integer(@quantity) > cap ? :exhausted_allowance : nil
    rescue ArgumentError, TypeError
      :ambiguous_configuration
    end

    def lock_usage_bucket!(root, account)
      key = "recording-studio-billing:usage:#{root.id}:#{account.id}:#{usage_key}"
      quoted_key = UsageEvent.connection.quote(key)
      UsageEvent.connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))")
    end

    private

    attr_reader :idempotency_key, :metadata, :occurred_at, :root_recording_input, :usage_key
  end
end