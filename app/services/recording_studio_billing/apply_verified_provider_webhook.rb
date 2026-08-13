# frozen_string_literal: true

module RecordingStudioBilling
  class ApplyVerifiedProviderWebhook
    ACTION_NAME = "recording_studio_billing.provider_event.v1"
    ACTION_VERSION = "v1"

    def self.call(context) = new(context).call

    def initialize(context)
      @context = context
    end

    def call
      return rejected unless valid_context?

      event = context.payload.to_h.stringify_keys
      object = event.fetch("data").to_h.fetch("object").to_h.stringify_keys
      ApplyProviderWebhook.call(inbound_event: context.inbound_event, remote_type: object.fetch("object"),
                                remote_id: object.fetch("id"))
    rescue KeyError, TypeError, NoMethodError, ArgumentError
      reject_if_trusted
    end

    private

    attr_reader :context

    def valid_context?
      context.respond_to?(:endpoint) && context.respond_to?(:inbound_event) && context.respond_to?(:payload) &&
        context.endpoint && context.inbound_event && context.endpoint.respond_to?(:identity) &&
        context.endpoint.identity.to_h.stringify_keys.slice(
          "billing_provider_adapter_key", "billing_provider_account_recording_id", "billing_environment"
        ).size == 3
    rescue NoMethodError, TypeError
      false
    end

    def reject_if_trusted
      return rejected unless context.respond_to?(:inbound_event)

      ApplyProviderWebhook.reject_verified(inbound_event: context.inbound_event, kind: "malformed_verified_webhook")
    rescue NoMethodError, TypeError
      rejected
    end

    def rejected = ApplyProviderWebhook::Result.new(status: :rejected, effect: nil)
  end
end
