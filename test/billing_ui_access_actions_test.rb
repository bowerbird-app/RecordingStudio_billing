# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class BillingUiAccessActionsTest < Minitest::Test
  def test_customer_actions_have_the_minimum_roles_used_by_customer_routes
    expected = {
      view_billing: :view,
      start_checkout: :edit,
      view_checkout: :view,
      request_subscription_change: :edit,
      cancel_subscription: :edit,
      resume_subscription: :edit,
      view_payments: :view,
      view_refunds: :view,
      view_adjustments: :view,
      view_invoices: :view,
      download_invoice: :view,
      edit_billing_settings: :edit
    }

    assert_equal expected, RecordingStudioBilling::AccessActions::CUSTOMER
    expected.each do |action, role|
      assert_equal role, RecordingStudioBilling::AccessActions.role_for(action)
      assert RecordingStudioBilling::AccessActions.customer_action?(action)
    end
  end

  def test_site_actions_are_admin_only_and_share_the_registered_catalog
    expected = %i[commercial_operations financial_operations reconciliation recovery]

    assert_equal expected, RecordingStudioBilling::AccessActions::SITE.keys
    expected.each do |action|
      assert_equal :admin, RecordingStudioBilling::AccessActions.role_for(action)
      refute RecordingStudioBilling::AccessActions.customer_action?(action)
    end
    assert_equal RecordingStudioBilling::AccessActions::CUSTOMER.merge(RecordingStudioBilling::AccessActions::SITE),
                 RecordingStudioBilling::AccessActions::ALL
  end

  def test_usage_ingestion_is_not_a_customer_accessible_action
    refute RecordingStudioBilling::AccessActions::ALL.key?(:record_usage)
    assert_raises(KeyError) { RecordingStudioBilling::AccessActions.role_for(:record_usage) }
  end

  def test_billable_roots_opt_into_accessible_grants
    assert RecordingStudio.capability_enabled?(:accessible, for: Workspace)
    assert_includes RecordingStudio.capability_child_recordables_for(:accessible), "RecordingStudio::Access"
  end

  def test_customer_mutation_routes_do_not_accept_get
    mutations = [
      "/billing/update_settings",
      "/billing/checkout",
      "/billing/portal",
      "/subscriptions/1/cancel",
      "/subscriptions/1/resume",
      "/subscriptions/1/compare_change",
      "/subscriptions/1/confirm_change"
    ]

    mutations.each do |path|
      assert_raises(ActionController::RoutingError) do
        RecordingStudioBilling::Engine.routes.recognize_path(path, method: :get)
      end
    end
  end
end
