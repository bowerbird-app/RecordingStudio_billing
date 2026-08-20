# frozen_string_literal: true

module RecordingStudioBilling
  class TaxRequest
    CLIENT_AUTHORITY_KEYS = /(?:tax|subtotal|total|rate|exemption|provider|calculator|currency|location)/i
    BEHAVIORS = TaxCalculatorCapabilities::BEHAVIORS

    attr_reader :root_recording, :account_recording, :manifest, :transaction_type, :operation_reference,
                :lines, :subtotal_minor, :discount_minor, :currency, :verified_location, :tax_categories,
                :behavior, :effective_at, :idempotency_key, :fingerprint

    def initialize(root_recording:, account_recording:, manifest:, transaction_type:, operation_reference:,
                   lines:, subtotal_minor:, discount_minor:, currency:, verified_location:, tax_categories:,
                   behavior:, effective_at:, idempotency_key:, client_payload: {})
      reject_client_authority!(client_payload)
      @root_recording = authoritative_root(root_recording)
      @account_recording = authoritative_account(account_recording)
      @manifest = authoritative_manifest(manifest)
      @transaction_type = normalize_key(transaction_type, "transaction type")
      @operation_reference = operation_reference.to_s
      @lines = normalize_lines(lines)
      @subtotal_minor = integer!(subtotal_minor, "subtotal")
      @discount_minor = integer!(discount_minor, "discount")
      @currency = currency.to_s.upcase
      @verified_location = normalize_location(verified_location)
      supplied_categories = Array(tax_categories).map { |value| normalize_key(value, "tax category") }.uniq.sort
      derived_categories = @lines.map { |line| line.fetch("tax_category") }.uniq.sort
      unless supplied_categories == derived_categories
        raise ArgumentError,
              "tax categories must exactly match normalized line categories"
      end

      @tax_categories = derived_categories.freeze
      @behavior = behavior.to_s
      @effective_at = effective_at&.in_time_zone
      @idempotency_key = idempotency_key.to_s
      validate!
      @fingerprint = CommercialManifestCanonicalizer.digest(to_h)
      freeze
    end

    def to_h
      {
        "root_recording_id" => root_recording.id, "account_recording_id" => account_recording.id,
        "transaction_type" => transaction_type, "operation_reference" => operation_reference,
        "commercial_manifest_id" => manifest.id, "commercial_manifest_digest" => manifest.manifest_digest,
        "lines" => lines, "subtotal_minor" => subtotal_minor, "discount_minor" => discount_minor,
        "currency" => currency, "verified_location" => verified_location, "tax_categories" => tax_categories,
        "behavior" => behavior, "effective_at" => effective_at.iso8601(6), "idempotency_key" => idempotency_key
      }
    end

    private

    def authoritative_root(value)
      root = RecordingStudio.root_recording_or_self(value)
      RecordingStudio.assert_root_recording!(root)
      RecordingStudio::Recording.unscoped.find(root.id).tap do |recording|
        raise ArgumentError, "tax root authority is invalid" if recording.trashed_at?
      end
    end

    def authoritative_account(value)
      recording = RecordingStudio::Recording.unscoped.find(value.respond_to?(:id) ? value.id : value)
      account = recording.recordable
      valid = recording.recordable_type == "RecordingStudioBilling::Account" && recording.trashed_at.nil? &&
              recording.root_recording_id == root_recording.id && recording.parent_recording_id == root_recording.id &&
              account.root_recording_id == root_recording.id
      raise ArgumentError, "tax account must belong directly to the normalized root" unless valid

      recording
    end

    def authoritative_manifest(value)
      record = value.is_a?(CommercialManifest) ? value.reload : CommercialManifest.find(value)
      raise ArgumentError, "tax manifest belongs to another root" unless record.root_recording_id == root_recording.id
      raise ArgumentError, "tax manifest is not published and used" unless record.used_at?

      record
    end

    def normalize_lines(values)
      Array(values).map do |line|
        data = line.respond_to?(:to_h) ? line.to_h.transform_keys(&:to_sym) : {}
        {
          "reference" => data.fetch(:reference).to_s,
          "quantity" => integer!(data.fetch(:quantity), "line quantity"),
          "amount_minor" => integer!(data.fetch(:amount_minor), "line amount"),
          "tax_category" => normalize_key(data.fetch(:tax_category), "line tax category")
        }.freeze
      end.freeze
    end

    def normalize_location(value)
      location = value.respond_to?(:to_h) ? value.to_h.transform_keys(&:to_s) : {}
      raise ArgumentError, "verified location must contain only country and region" if (location.keys - %w[country
                                                                                                           region]).any?

      location.transform_values { |item| item.to_s.upcase }.freeze
    end

    def reject_client_authority!(value)
      payload = value.respond_to?(:to_h) ? value.to_h : {}
      forbidden = payload.keys.find { |key| key.to_s.match?(CLIENT_AUTHORITY_KEYS) }
      raise ArgumentError, "client payload cannot author tax authority" if forbidden

      SafeFinancialPayload.normalize(payload)
    end

    def validate!
      raise ArgumentError, "tax lines are required" if lines.empty?
      raise ArgumentError, "tax subtotal must equal approved lines" unless lines.sum do |line|
        line.fetch("amount_minor")
      end == subtotal_minor
      raise ArgumentError, "tax discount is invalid" unless discount_minor.between?(0, subtotal_minor)
      raise ArgumentError, "tax currency is invalid" unless currency.match?(/\A[A-Z]{3}\z/)
      raise ArgumentError, "verified tax country is required" unless verified_location.fetch("country",
                                                                                             "").match?(/\A[A-Z]{2}\z/)
      raise ArgumentError, "tax behavior is invalid" unless BEHAVIORS.include?(behavior)
      raise ArgumentError, "tax effective time is required" unless effective_at
      raise ArgumentError, "tax operation reference is required" if operation_reference.empty?
      raise ArgumentError, "tax idempotency key is required" if idempotency_key.empty?

      SafeFinancialPayload.normalize_reference(operation_reference, label: "tax operation reference")
      SafeFinancialPayload.normalize_reference(idempotency_key, label: "tax idempotency key")
      lines.each do |line|
        SafeFinancialPayload.normalize_reference(line.fetch("reference"), label: "tax line reference", maximum: 128)
      end
    end

    def normalize_key(value, label)
      key = value.to_s
      raise ArgumentError, "#{label} is invalid" unless key.match?(/\A[a-z][a-z0-9_]*\z/)

      key
    end

    def integer!(value, label)
      raise ArgumentError, "#{label} must use integer minor units" unless value.is_a?(Integer)

      value
    end
  end
end
