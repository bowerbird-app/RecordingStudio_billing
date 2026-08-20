# frozen_string_literal: true

module RecordingStudioBilling
  # Safe to run from a scheduler more than once or from concurrent workers.
  class DueCommercialPublicationActivator
    def self.call(actor:, now: Time.current)
      new(now:, actor:).call
    end

    def initialize(now:, actor:)
      @now = now
      @actor = actor
    end

    def call
      activated = []
      attempted_ids = []

      loop do
        publication = claim_and_activate(attempted_ids)
        break unless publication

        attempted_ids << publication.id
        activated << publication if publication.activated?
      end

      activated
    end

    private

    def claim_and_activate(attempted_ids)
      CommercialPublicationCandidate.transaction(requires_new: true) do
        candidate = due_candidates.where.not(id: attempted_ids).lock("FOR UPDATE SKIP LOCKED").first
        return unless candidate

        attempted_ids << candidate.id
        CommercialPublisher.activate!(candidate:, actor: @actor, now: @now)
      rescue CommercialPublisher::InvalidCandidateError
        candidate
      end
    end

    def due_candidates
      CommercialPublicationCandidate.where(activated_at: nil)
                                    .where(effective_at: ..@now)
                                    .order(:effective_at, :id)
    end
  end
end
