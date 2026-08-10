# frozen_string_literal: true

module RecordingStudioBilling
  class CommercialPublicationCandidate < ApplicationRecord
    validates :candidate_digest, format: { with: /\A\h{64}\z/ }, uniqueness: true
    validates :effective_at, :manifest_digests, :recording_snapshots, presence: true
    validate :immutable_after_activation, on: :update

    def activated?
      activated_at?
    end

    private

    def immutable_after_activation
      return unless activated_at_was.present? && changed?

      errors.add(:base, "activated publication candidates are immutable")
    end
  end
end
