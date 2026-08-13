# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class BillingUiSubscriptionProposalsTest < Minitest::Test
  def test_comparison_request_accepts_only_supported_server_resolvable_fields
    controller = controller_with(
      subscription_change: { change_kind: "plan", billing_option_recording_id: "option-1", quantity: "2",
                             manifest_digest: "forged" }
    )

    assert_equal(
      { "change_kind" => "plan", "billing_option_recording_id" => "option-1", "quantity" => "2" },
      controller.send(:comparison_request)
    )
  end

  def test_comparison_request_rejects_unknown_change_kind
    controller = controller_with(subscription_change: { change_kind: "forged",
                                                        billing_option_recording_id: "option-1" })

    assert_raises(ActionController::ParameterMissing) { controller.send(:comparison_request) }
  end

  def test_comparison_request_rejects_missing_commercial_selection
    controller = controller_with(subscription_change: { change_kind: "plan", quantity: "2" })

    assert_raises(ActionController::ParameterMissing) { controller.send(:comparison_request) }
  end

  def test_proposal_rejects_expired_or_cross_context_session_entries
    controller = controller_with(subscription_change: { proposal_key: "proposal" })
    controller.instance_variable_set(:@comparison_proposals, {
                                       "proposal" => valid_proposal.merge("expires_at" => 1.second.ago.to_i)
                                     })

    assert_raises(ArgumentError) { controller.send(:comparison_proposal!) }

    controller.instance_variable_set(:@comparison_proposals, {
                                       "proposal" => valid_proposal.merge("root_recording_id" => "other-root")
                                     })
    assert_raises(ArgumentError) { controller.send(:comparison_proposal!) }
  end

  private

  def controller_with(params)
    controller = RecordingStudioBilling::SubscriptionsController.new
    root = Struct.new(:id).new("root")
    account = Struct.new(:id).new("account")
    subscription = Struct.new(:id).new("subscription")
    controller.define_singleton_method(:params) { ActionController::Parameters.new(params) }
    controller.define_singleton_method(:root_recording) { root }
    controller.define_singleton_method(:account_recording) { account }
    controller.instance_variable_set(:@subscription, subscription)
    controller.define_singleton_method(:comparison_proposals) { @comparison_proposals ||= {} }
    controller
  end

  def valid_proposal
    {
      "root_recording_id" => "root", "account_recording_id" => "account", "subscription_id" => "subscription",
      "expires_at" => 15.minutes.from_now.to_i
    }
  end
end
