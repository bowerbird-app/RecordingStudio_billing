# frozen_string_literal: true

module RecordingStudioBilling
  class CommercialPublicationCandidate < RecordingStudioBilling::ApplicationRecord
    validates :candidate_digest, format: { with: /\A\h{64}\z/ }, uniqueness: true
    validates :effective_at, :manifest_digests, :recording_snapshots, :snapshot_envelope, presence: true
    validate :immutable_after_creation, on: :update

    def activated?
      activated_at?
    end

    private

    def immutable_after_creation
      allowed_activation = activated_at_was.nil? && activated_at? && changed_attribute_names_to_save == ["activated_at"]
      return if allowed_activation || !changed?

      errors.add(:base, "commercial publication candidates are immutable")
    end
  end
end
