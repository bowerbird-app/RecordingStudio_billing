# frozen_string_literal: true

module RecordingStudioBilling
  class ExpireUsageCredits
    Result = Data.define(:status, :entries) do
      def expired? = status == :expired
      def existing? = status == :existing
    end

    def self.call(...) = new(...).call

    def initialize(root_recording:, account_recording:, credit_key:, at: Time.current)
      @root_recording = root_recording
      @account_recording = account_recording
      @credit_key = credit_key.to_s
      @at = at.to_time
    end

    def call
      UsageCreditGrant.transaction(requires_new: true) do
        root, account = authority!

        lock_bucket!(root, account)
        expired = expiring_grants(root, account).map { |grant| expire!(grant, root, account) }
        Result.new(status: expired.any?(&:last) ? :expired : :existing, entries: expired.map(&:first).compact)
      end
    end

    private

    attr_reader :account_recording, :at, :credit_key, :root_recording

    def authority!
      root = RecordingStudio.root_recording_or_self(root_recording)
      RecordingStudio.assert_root_recording!(root)
      root = RecordingStudio::Recording.unscoped.find(root.id)
      account_id = account_recording.respond_to?(:id) ? account_recording.id : account_recording
      account = RecordingStudio::Recording.unscoped.find(account_id)
      valid = account.recordable_type == "RecordingStudioBilling::Account" && account.root_recording_id == root.id &&
              account.parent_recording_id == root.id && account.recordable.root_recording_id == root.id
      raise ArgumentError, "billing account must belong directly to the normalized root" unless valid

      [root, account]
    end

    def expiring_grants(root, account)
      UsageCreditGrant.where(root_recording: root, account_recording: account, credit_key:)
                      .where.not(expires_at: nil).where(expires_at: ..at).order(:expires_at, :created_at, :id).lock.to_a
    end

    def expire!(grant, root, account)
      period = UsagePeriod.where(root_recording: root, account_recording: account, usage_key: credit_key)
                          .where("starts_at <= ? AND ends_at > ?", grant.expires_at, grant.expires_at).lock.first
      raise ArgumentError, "expired credit has no authoritative usage period" unless period

      existing = UsageLedgerEntry.find_by(usage_period: period, usage_credit_grant: grant, entry_kind: "expire")
      return [existing, false] if existing
      return [nil, false] if grant.available_quantity <= 0

      [UsageLedgerEntry.create!(
        root_recording: root, account_recording: account, usage_period: period, usage_credit_grant: grant,
        entry_kind: "expire", quantity: grant.available_quantity,
        sequence: period.usage_ledger_entries.maximum(:sequence).to_i + 1,
        safe_metadata: { "expired_at" => grant.expires_at.utc.iso8601(6) }
      ), true]
    end

    def lock_bucket!(root, account)
      key = "recording-studio-billing:usage-credit-expiry:#{root.id}:#{account.id}:#{credit_key}"
      quoted_key = UsageCreditGrant.connection.quote(key)
      UsageCreditGrant.connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))")
    end
  end
end
