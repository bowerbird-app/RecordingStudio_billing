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
      CommercialPublicationCandidate.where(activated_at: nil).where(effective_at: ..@now).order(:effective_at, :id)
                                    .filter_map do |candidate|
        CommercialPublisher.activate!(candidate:, actor: @actor, now: @now)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError
        nil
      end
    end
  end
end
