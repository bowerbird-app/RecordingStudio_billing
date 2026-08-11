# frozen_string_literal: true

require "securerandom"

module RecordingStudioBilling
  class CreateFinancialCommand
    Result = Data.define(:status, :command) do
      def created? = status == :created
      def existing? = status == :existing
      def conflict? = status == :conflict
    end

    def self.call(...)
      new(...).call
    end

    def initialize(root_recording:, account_recording:, command_type:, local_idempotency_key:, request:,
                   provider_account_recording: nil, provider_adapter_key: nil, calculator_key: nil,
                   calculator_mode: nil, commercial_manifest_digests: [])
      @root_recording_input = root_recording
      @account_recording_input = account_recording
      @provider_account_recording_input = provider_account_recording
      @provider_adapter_key = provider_adapter_key&.to_s
      @command_type = command_type.to_s
      @local_idempotency_key = local_idempotency_key.to_s
      @request = request
      @calculator_key = calculator_key&.to_s
      @calculator_mode = calculator_mode&.to_s
      @commercial_manifest_digests = Array(commercial_manifest_digests).map(&:to_s).uniq.sort
    end

    def call
      attributes = nil
      FinancialCommand.transaction(requires_new: true) do
        attributes = command_attributes
        command = FinancialCommand.create!(attributes)
        Result.new(status: :created, command:)
      end
    rescue ActiveRecord::RecordNotUnique
      existing = FinancialCommand.find_by!(
        root_recording_id: attributes.fetch(:root_recording_id),
        local_idempotency_key: attributes.fetch(:local_idempotency_key)
      )
      status = existing.request_fingerprint == attributes.fetch(:request_fingerprint) ? :existing : :conflict
      Result.new(status:, command: existing)
    end

    private

    attr_reader :account_recording_input, :calculator_key, :calculator_mode, :command_type, :commercial_manifest_digests,
          :local_idempotency_key, :provider_account_recording_input, :provider_adapter_key, :request,
          :root_recording_input

    def command_attributes
      validate_scalar_inputs!
      root = canonical_root
      account_recording = authoritative_recording(account_recording_input, "RecordingStudioBilling::Account")
      verify_direct_account!(account_recording, root)
      provider_recording = authoritative_provider_recording
      manifest_digests = authoritative_manifest_digests(root)
      canonical_request = canonical_envelope(root, account_recording, provider_recording, manifest_digests)
      operation_id = SecureRandom.uuid

      {
        operation_id:,
        command_type:,
        root_recording_id: root.id,
        account_recording_id: account_recording.id,
        provider_account_recording_id: provider_recording&.id,
        provider_adapter_key:,
        calculator_key:,
        calculator_mode:,
        canonical_request:,
        request_fingerprint: CommercialManifestCanonicalizer.digest(canonical_request),
        local_idempotency_key:,
        provider_idempotency_key: "rsb-#{operation_id}"
      }
    end

    def canonical_root
      root = RecordingStudio.root_recording_or_self(root_recording_input)
      RecordingStudio.assert_root_recording!(root)
      root = RecordingStudio::Recording.unscoped.find(root.id)
      raise ArgumentError, "root Recording is trashed" if root.trashed_at?

      root
    end

    def authoritative_recording(value, expected_type)
      recording_id = value.respond_to?(:id) ? value.id : value
      recording = RecordingStudio::Recording.unscoped.find(recording_id)
      raise ArgumentError, "authority Recording is trashed" if recording.trashed_at?
      return recording if recording.recordable_type == expected_type

      raise ArgumentError, "recording must contain a #{expected_type}"
    end

    def verify_direct_account!(recording, root)
      account = recording.recordable
      valid = recording.root_recording_id == root.id && recording.parent_recording_id == root.id &&
              account.root_recording_id == root.id
      raise ArgumentError, "billing account must belong directly to the normalized root" unless valid
    end

    def authoritative_provider_recording
      return unless provider_account_recording_input

      recording = authoritative_recording(provider_account_recording_input, "RecordingStudioBilling::ProviderAccount")
      billing_admin_recording = recording.recordable.billing_admin_recording
      valid = billing_admin_recording.recordable_type == "RecordingStudioBilling::BillingAdmin" &&
              billing_admin_recording.trashed_at.nil? &&
              recording.parent_recording_id == billing_admin_recording.id &&
              recording.root_recording_id == billing_admin_recording.root_recording_id
      raise ArgumentError, "provider account must belong directly to its BillingAdmin" unless valid
      unless recording.recordable.adapter_key == provider_adapter_key
        raise ArgumentError, "provider account adapter key does not match the financial command"
      end

      recording
    end

    def authoritative_manifest_digests(root)
      return [] if commercial_manifest_digests.empty?

      raise ArgumentError, "commercial manifest immutability is not enforced" unless manifest_history_protected?

      manifests = CommercialManifest.where(manifest_digest: commercial_manifest_digests).order(:manifest_digest).lock.to_a
      raise ArgumentError, "commercial manifests are missing" unless manifests.size == commercial_manifest_digests.size

      manifests.each do |manifest|
        raise ArgumentError, "commercial manifest belongs to another root" unless manifest.root_recording_id == root.id
        raise ArgumentError, "commercial manifest is not published and used" unless manifest.used_at?
        unless manifest.schema_version == CommercialManifest::SCHEMA_VERSION &&
               manifest.resolver_version == CommercialManifest::RESOLVER_VERSION
          raise ArgumentError, "commercial manifest version is unsupported"
        end

        envelope = {
          "schema_version" => manifest.schema_version,
          "resolver_version" => manifest.resolver_version,
          "root_recording_id" => manifest.root_recording_id,
          "canonical_data" => manifest.canonical_data,
          "recording_snapshots" => manifest.recording_snapshots,
          "snapshot_references" => manifest.snapshot_references
        }
        unless CommercialManifestCanonicalizer.digest(envelope) == manifest.manifest_digest
          raise ArgumentError, "commercial manifest digest is invalid"
        end
      end

      commercial_manifest_digests
    end

    def manifest_history_protected?
      FinancialCommand.connection.select_value(<<~SQL.squish) == true
        SELECT EXISTS (
          SELECT 1 FROM pg_trigger
          WHERE tgrelid = 'recording_studio_billing_commercial_manifests'::regclass
            AND tgname = 'rs_billing_manifests_protect_history'
            AND tgenabled <> 'D'
        )
      SQL
    end

    def canonical_envelope(root, account_recording, provider_recording, manifest_digests)
      payload = SafeFinancialPayload.normalize(request, allow_authoritative_totals: command_type == "tax_calculation")

      {
        "schema_version" => "v1",
        "authority" => {
          "root_recording_id" => root.id,
          "account_recording_id" => account_recording.id,
          "command_type" => command_type,
          "provider_account_recording_id" => provider_recording&.id,
          "provider_adapter_key" => provider_adapter_key,
          "calculator_key" => calculator_key,
          "calculator_mode" => calculator_mode,
          "commercial_manifest_digests" => manifest_digests
        },
        "request" => payload
      }
    end

    def validate_scalar_inputs!
      raise ArgumentError, "command type is invalid" unless command_type.match?(/\A[a-z][a-z0-9_]*\z/)
      raise ArgumentError, "local idempotency key is required" if local_idempotency_key.empty?
      provider_authority = provider_account_recording_input.present? && provider_adapter_key.present?
      tax_authority = calculator_key.present? && calculator_mode.present?
      return if provider_authority ^ tax_authority

      raise ArgumentError, "exactly one provider adapter or calculator is required"
    end
  end
end