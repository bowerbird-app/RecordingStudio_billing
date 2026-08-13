# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class BillingUiSubscriptionChangeAuthorityTest < Minitest::Test
  def test_comparison_proposal_is_bound_to_root_account_subscription_and_expiry
    controller = controller_with(subscription_change: { proposal_key: "proposal" })
    controller.instance_variable_set(:@comparison_proposals, { "proposal" => proposal })

    assert_equal proposal, controller.send(:comparison_proposal!)

    %w[root_recording_id account_recording_id subscription_id].each do |attribute|
      controller.instance_variable_set(:@comparison_proposals, { "proposal" => proposal.merge(attribute => "forged") })
      assert_raises(ArgumentError) { controller.send(:comparison_proposal!) }
    end

    controller.instance_variable_set(:@comparison_proposals,
                                     { "proposal" => proposal.merge("expires_at" => 1.second.ago.to_i) })
    assert_raises(ArgumentError) { controller.send(:comparison_proposal!) }
  end

  def test_confirmation_params_do_not_permit_client_manifest_or_commercial_terms
    controller = controller_with(subscription_change: {
                                   proposal_key: "proposal", manifest_digest: "forged", billing_option_recording_id: "forged",
                                   quantity: "99", change_kind: "addon", market: "forged", currency: "USD", amount_minor: 1,
                                   total_minor: 1, tax_minor: 1, provider_subscription_reference: "sub_forged", provider_url: "https://evil.example"
                                 })

    assert_equal({ "proposal_key" => "proposal" }, controller.send(:confirmation_params).to_h)
  end

  def test_comparison_params_allow_only_server_resolvable_selection_fields
    controller = controller_with(subscription_change: {
                                   change_kind: "plan", billing_option_recording_id: "option", quantity: "2", manifest_digest: "forged", currency: "USD"
                                 })

    assert_equal({ "change_kind" => "plan", "billing_option_recording_id" => "option", "quantity" => "2" },
                 controller.send(:comparison_request))
  end

  def test_comparison_request_drops_client_financial_tax_and_provider_authority
    controller = controller_with(subscription_change: {
                                   change_kind: "quantity", billing_option_recording_id: "option", quantity: "2", amount_minor: "1",
                                   total: "1", tax: "forged", provider_id: "provider", provider_url: "https://evil.example", currency: "USD"
                                 })

    assert_equal({ "change_kind" => "quantity", "billing_option_recording_id" => "option", "quantity" => "2" },
                 controller.send(:comparison_request))
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

  def proposal
    {
      "root_recording_id" => "root", "account_recording_id" => "account", "subscription_id" => "subscription",
      "current_manifest_digests" => ["current"], "billing_option_recording_id" => "option", "quantity" => 1,
      "change_kind" => "plan", "provider_root_recording_id" => "provider-root", "manifest_digest" => "digest",
      "expires_at" => 15.minutes.from_now.to_i
    }
  end
end
