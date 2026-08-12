# frozen_string_literal: true

module RecordingStudioBilling
  class ConsumeCredits
    Result = Data.define(:status, :entry, :usage_event, :reason) do
      def created? = status == :created
      def existing? = status == :existing
      def denied? = status == :denied
    end

    def self.call(...) = new(...).call

    def initialize(root_recording:, product_recording:, amount:, usage_key:, idempotency_key:, metadata: {})
      @root_recording_input = root_recording
      @product_recording = product_recording
      @amount = amount
      @usage_key = usage_key
      @idempotency_key = idempotency_key
      @metadata = metadata
    end

    def call
      recorder = RecordUsage.new(root_recording: root_recording_input, usage_key:, quantity: amount, idempotency_key:, metadata:)
      root, account = recorder.authority!
      product_id = product_recording.respond_to?(:id) ? product_recording.id : product_recording
      amount = Integer(@amount)
      raise ArgumentError, "credit amount must be positive" unless amount.positive?

      existing = CreditLedgerEntry.find_by(root_recording: root, idempotency_key:, direction: "debit")
      return Result.new(status: :existing, entry: existing, usage_event: existing.usage_event, reason: nil) if existing

      result = nil
      CreditLedgerEntry.transaction do
        usage = recorder.call
        if usage.denied?
          result = Result.new(status: :denied, entry: nil, usage_event: nil, reason: usage.reason)
          raise ActiveRecord::Rollback
        end

        existing = CreditLedgerEntry.find_by(root_recording: root, idempotency_key:, direction: "debit")
        if existing
          result = Result.new(status: :existing, entry: existing, usage_event: existing.usage_event, reason: nil)
          next
        end

        lock_balance!(root, account, product_id)
        credit = CreditLedgerEntry.where(root_recording: root, account_recording: account, product_recording_id: product_id,
                                         credit_key: usage_key, direction: "credit").order(:effective_at, :id).first
        unless credit
          result = Result.new(status: :denied, entry: nil, usage_event: nil, reason: :insufficient_credit_balance)
          raise ActiveRecord::Rollback
        end
        balance = CreditLedgerEntry.where(root_recording: root, account_recording: account, product_recording_id: product_id)
                                   .where(effective_at: ..Time.current).sum(:amount)
        if balance < amount
          result = Result.new(status: :denied, entry: nil, usage_event: nil, reason: :insufficient_credit_balance)
          raise ActiveRecord::Rollback
        end

        entry = CreditLedgerEntry.create!(root_recording: root, account_recording: account, product_recording_id: product_id,
                                          manifest_digest: credit.manifest_digest, credit_key: usage_key, amount: -amount,
                                          effective_at: Time.current, direction: "debit", usage_event: usage.event,
                                          idempotency_key:, safe_metadata: SafeFinancialPayload.normalize(metadata))
        result = Result.new(status: :created, entry:, usage_event: usage.event, reason: nil)
      end
      result
    rescue ActiveRecord::RecordNotUnique
      entry = CreditLedgerEntry.find_by!(root_recording: root, idempotency_key:, direction: "debit")
      Result.new(status: :existing, entry:, usage_event: entry.usage_event, reason: nil)
    end

    private

    attr_reader :amount, :idempotency_key, :metadata, :product_recording, :root_recording_input, :usage_key

    def lock_balance!(root, account, product_id)
      key = "recording-studio-billing:credits:#{root.id}:#{account.id}:#{product_id}"
      quoted_key = CreditLedgerEntry.connection.quote(key)
      CreditLedgerEntry.connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))")
    end
  end
end