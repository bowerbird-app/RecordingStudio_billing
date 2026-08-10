# frozen_string_literal: true

module RecordingStudioBilling
  class CommercialManifest < ApplicationRecord
    self.implicit_order_column = :created_at

    SCHEMA_VERSION = "v1"
    RESOLVER_VERSION = "v1"

    validates :schema_version, inclusion: { in: [SCHEMA_VERSION] }
    validates :resolver_version, inclusion: { in: [RESOLVER_VERSION] }
    validates :manifest_digest, format: { with: /\A\h{64}\z/ }, uniqueness: true
    validates :canonical_data, :recording_snapshots, :snapshot_references, presence: true
    validate :digest_matches_canonical_data
    validate :immutable_after_creation, on: :update

    def mark_used!
      update!(used_at: Time.current) unless used_at?
    end

    private

    def digest_matches_canonical_data
      return if canonical_data.blank? || manifest_digest.blank?

      calculated = CommercialManifestCanonicalizer.digest(canonical_data)
      errors.add(:manifest_digest, "does not match canonical data") unless calculated == manifest_digest
    rescue CommercialManifestCanonicalizer::UnsupportedValue => e
      errors.add(:canonical_data, e.message)
    end

    def immutable_after_creation
      allowed_use_mark = used_at_was.nil? && used_at? && changed_attribute_names_to_save == ["used_at"]
      return if allowed_use_mark || !changed?

      errors.add(:base, "commercial manifests are immutable")
    end
  end
end
