# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionLifecycle
    TRANSITIONS = {
      "trialing" => %w[active paused cancelled expired],
      "active" => %w[past_due paused cancelled expired],
      "past_due" => %w[active paused cancelled expired],
      "paused" => %w[active cancelled expired],
      "cancelled" => [],
      "expired" => []
    }.freeze

    def self.activate(subscription:, root_recording: nil) = transition(subscription:, root_recording:, to: "active")
    def self.cancel(subscription:, root_recording: nil) = transition(subscription:, root_recording:, to: "cancelled")
    def self.pause(subscription:, root_recording: nil) = transition(subscription:, root_recording:, to: "paused")
    def self.resume(subscription:, root_recording: nil) = transition(subscription:, root_recording:, to: "active")
    def self.resume_from_change(subscription:, root_recording: nil) = transition(subscription:, root_recording:, to: "active", allow_cancelled: true)
    def self.expire(subscription:, root_recording: nil) = transition(subscription:, root_recording:, to: "expired")

    def self.transition(subscription:, root_recording:, to:, allow_cancelled: false)
      Subscription.transaction do
        record = Subscription.lock.find(subscription.respond_to?(:id) ? subscription.id : subscription)
        root = RecordingStudio.root_recording_or_self(root_recording || record.root_recording)
        raise ActiveRecord::RecordNotFound, "subscription not found" unless record.root_recording_id == root.id

        allowed = TRANSITIONS.fetch(record.state).include?(to) || (allow_cancelled && record.state == "cancelled" && to == "active")
        unless allowed
          raise ArgumentError,
                "subscription lifecycle transition is invalid"
        end

        record.update!(state: to)
        record
      end
    end
  end
end
