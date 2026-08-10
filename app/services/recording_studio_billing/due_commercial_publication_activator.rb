# frozen_string_literal: true

module RecordingStudioBilling
  # Safe to run from a scheduler more than once or from concurrent workers.
  class DueCommercialPublicationActivator
    def self.call(now: Time.current)
      new(now:).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      CommercialPublicationCandidate.where(activated_at: nil).where(effective_at: ..@now).order(:effective_at, :id)
                                    .find_each.filter_map do |candidate|
        CommercialPublisher.activate!(candidate:)
      rescue ActiveRecord::RecordNotFound
        nil
      end
    end
  end
end
