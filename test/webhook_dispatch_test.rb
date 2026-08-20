# frozen_string_literal: true

require "test_helper"
require "recording_studio_webhooks"
require_relative "../app/services/recording_studio_billing/apply_provider_webhook"
require_relative "../app/services/recording_studio_billing/apply_verified_provider_webhook"

class WebhookDispatchTest < Minitest::Test
  Endpoint = Struct.new(:provider_name, :identity)
  InboundEvent = Struct.new(:id, :provider_event_id)
  Context = Struct.new(:endpoint, :inbound_event, :payload)

  def test_registered_action_uses_only_verified_context_and_endpoint_authority
    received = nil
    context = Context.new(
      Endpoint.new("stripe", {
                     "billing_provider_adapter_key" => "stripe",
                     "billing_provider_account_recording_id" => "provider-recording",
                     "billing_environment" => "production"
                   }),
      InboundEvent.new("7c2c8a43-5df3-49ba-8da2-03a2eac3e8e5", "evt_123"),
      { "id" => "evt_123", "data" => { "object" => { "object" => "checkout.session", "id" => "cs_123" } } }
    )

    RecordingStudioBilling::ApplyProviderWebhook.stub(:call, ->(**attributes) { received = attributes }) do
      RecordingStudioBilling::ApplyVerifiedProviderWebhook.call(context)
    end

    assert_same context.inbound_event, received.fetch(:inbound_event)
    assert_equal "checkout.session", received.fetch(:remote_type)
    assert_equal "cs_123", received.fetch(:remote_id)
  end

  def test_action_registration_uses_the_webhooks_verified_dispatch_registry
    RecordingStudioBilling.register_webhook_actions!

    action = RecordingStudioWebhooks.actions.fetch(RecordingStudioBilling::ApplyVerifiedProviderWebhook::ACTION_NAME)
    assert_equal RecordingStudioBilling::ApplyVerifiedProviderWebhook, action.implementation
    assert action.matches?("stripe", "checkout.session.completed")
  end

  def test_malformed_dispatch_context_and_fabricated_receipt_fail_closed
    malformed = RecordingStudioBilling::ApplyVerifiedProviderWebhook.call(Object.new)
    fabricated = RecordingStudioBilling::ApplyProviderWebhook.call(
      inbound_event: InboundEvent.new(SecureRandom.uuid,
                                      "evt_123"), remote_type: "checkout.session", remote_id: "cs_123"
    )

    assert malformed.rejected?
    assert fabricated.rejected?
  end
end
