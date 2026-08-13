# frozen_string_literal: true

require "test_helper"

class RecordingStudioV3TemplateTest < ActiveSupport::TestCase
  test "dummy app loads root switchable configuration and billing admin support" do
    assert_equal ["all_workspaces"], RecordingStudioRootSwitchable.configuration.scopes.keys
    assert_equal :application_layout, RecordingStudioRootSwitchable.configuration.layout
    assert_includes ApplicationController.ancestors, RecordingStudio::RootSwitchable::ControllerSupport
    assert_includes AdminRoot.ancestors, RecordingStudioBilling::BillingAdminSupport
    assert_equal %w[billing_commercial billing_financial billing_operations],
                 AdminRoot.recording_studio_admin_section_keys_for(nil, nil, nil)
  end

  test "billing admin definitions are registered at site scope" do
    keys = %w[billing_commercial billing_financial billing_operations]
    operation_keys = RecordingStudioBilling::ADMIN_OPERATION_AREAS.keys.map(&:to_s)

    assert_equal keys, RecordingStudioAdmin.sections.keys.grep(/^billing_/).sort
    assert_equal (keys + operation_keys).sort, RecordingStudioAdmin.screens.keys.grep(/^billing_/).sort
    assert_equal (keys + operation_keys).sort, RecordingStudioAdmin.resources.keys.grep(/^billing_/).sort

    keys.each do |key|
      assert_equal :site, RecordingStudioAdmin.section_for(key).blast_radius
    end

    (keys + operation_keys).each do |key|
      assert_equal :site, RecordingStudioAdmin.screen_for(key).blast_radius
      assert_equal :site, RecordingStudioAdmin.resource_for(key).blast_radius
    end

    RecordingStudioBilling::ADMIN_OPERATION_AREAS.each do |key, definition|
      screen = RecordingStudioAdmin.screen_for(key)
      expected_model = "RecordingStudioBilling::#{definition.fetch(:model)}".constantize

      assert_equal expected_model, screen.query.call(nil).klass
      assert_equal definition.fetch(:section), RecordingStudioAdmin.resource_for(key).section_key
    end

    context = Class.new do
      def admin_screen_path(key) = "/admin/screens/#{key}"
    end.new
    RecordingStudioBilling::ADMIN_INVESTIGATION_RESOURCES.each do |key|
      resource = RecordingStudioAdmin.resource_for(key)
      action = resource.action_for(:investigate)

      assert_equal :site, action.blast_radius
      assert_equal :view, action.required_access_role
      assert_equal "/admin/screens/#{key}", action.resolve(Object.new, context).url
    end
  end

  test "dummy app validates the billing recordable hierarchy" do
    assert RecordingStudio.validate_recordable_declarations!
    assert_equal %w[AdminRoot Workspace], RecordingStudio.root_recordable_types.sort
    assert_equal ["Workspace"], RecordingStudio.allowed_parent_types_for("RecordingStudioBilling::Account")
    assert_equal ["AdminRoot"], RecordingStudio.allowed_parent_types_for("RecordingStudioBilling::BillingAdmin")
  end

  test "dummy seeds create an idempotent credential-free demonstration catalogue" do
    Current.actor = nil

    load Rails.root.join("db/seeds.rb").to_s

    workspace = Workspace.find_by!(name: "Studio Workspace")
    admin_root = AdminRoot.find_by!(name: "Billing Administration")
    account = RecordingStudioBilling::Account.find_by!(name: "Studio Account")
    billing_admin = RecordingStudioBilling::BillingAdmin.find_by!(key: "billing")
    workspace_recording = RecordingStudio::Recording.find_by!(recordable: workspace)
    admin_root_recording = RecordingStudio::Recording.find_by!(recordable: admin_root)
    account_recording = RecordingStudio::Recording.find_by!(recordable: account)
    billing_admin_recording = RecordingStudio::Recording.find_by!(recordable: billing_admin)

    assert_nil Current.actor
    assert_nil workspace_recording.parent_recording_id
    assert_nil admin_root_recording.parent_recording_id
    assert_equal workspace_recording, account_recording.parent_recording
    assert_equal admin_root_recording, billing_admin_recording.parent_recording
    assert_equal 1, Workspace.count
    assert_equal 1, AdminRoot.count
    assert_equal 1, RecordingStudioBilling::Account.count
    assert_equal 1, RecordingStudioBilling::BillingAdmin.count
    assert_equal %w[demo_fake_provider demo_stripe_test_provider], RecordingStudioBilling::ProviderAccount.with_current_recording.order(:key).pluck(:key)
    provider = RecordingStudioBilling::ProviderAccount.with_current_recording.find_by!(key: "demo_fake_provider")
    assert_equal "fake", provider.adapter_key
    assert_equal({}, provider.configuration)
    stripe_provider = RecordingStudioBilling::ProviderAccount.with_current_recording.find_by!(key: "demo_stripe_test_provider")
    assert_equal "stripe", stripe_provider.adapter_key
    assert_equal({ "display_name" => "Stripe test" }, stripe_provider.configuration)
    assert_equal %w[demo_annual_plan demo_checkout_product demo_credit_pack demo_free_plan demo_monthly_plan demo_quantity_addon demo_usage_product], RecordingStudioBilling::Product.with_current_recording.order(:key).pluck(:key)
    assert_equal 7, RecordingStudioBilling::BillingOption.with_current_recording.count
    assert_equal %w[demo_api_call], RecordingStudioBilling::UsageUnit.with_current_recording.order(:key).pluck(:key)
    assert_equal %w[demo_api_calls], RecordingStudioBilling::Meter.with_current_recording.order(:key).pluck(:key)
    assert_equal %w[demo_usage_rates], RecordingStudioBilling::RateCard.with_current_recording.order(:key).pluck(:key)
    assert_equal %w[demo_api_call_conversion], RecordingStudioBilling::Rate.with_current_recording.order(:key).pluck(:key)
    assert_equal %w[demo_usage_costs], RecordingStudioBilling::CostCard.with_current_recording.order(:key).pluck(:key)
    assert_equal %w[demo_api_call_cost], RecordingStudioBilling::CostRate.with_current_recording.order(:key).pluck(:key)
    assert_equal %w[demo_usage_api_overage], RecordingStudioBilling::OveragePrice.with_current_recording.order(:key).pluck(:key)
    assert_equal "published", RecordingStudioBilling::Price.with_current_recording.find_by!(key: "demo_usage_us_price").state
    assert_equal "published", RecordingStudioBilling::OveragePrice.with_current_recording.find_by!(key: "demo_usage_api_overage").state
    assert_equal "published", RecordingStudioBilling::Price.with_current_recording.find_by!(key: "demo_monthly_plan_us_price").state
    plan_amounts = %w[demo_free_plan demo_monthly_plan demo_annual_plan].map do |key|
      RecordingStudioBilling::Price.with_current_recording.find_by!(key: "#{key}_us_price").amount_minor
    end
    assert_equal [0, 4_900, 49_000], plan_amounts.sort
    assert_equal "requires", RecordingStudioBilling::ProductRule.with_current_recording.find_by!(key: "demo_addon_requires_plan").rule_type
    assert_equal "published", RecordingStudioBilling::PlanUpdate.with_current_recording.find_by!(key: "demo_monthly_plan_review").state
    invoice = RecordingStudioBilling::Invoice.find_by!(provider_reference: "demo_invoice_001")
    payment = RecordingStudioBilling::Payment.find_by!(provider_reference: "demo_payment_001")
    assert_equal invoice, payment.invoice
    assert_equal "paid", invoice.state
    assert_equal "completed", RecordingStudioBilling::RefundIntent.find_by!(local_idempotency_key: "seed:refund").state
    assert_equal 200, RecordingStudioBilling::Refund.find_by!(provider_reference: "demo_refund_001").amount_minor
    assert_equal "credit", RecordingStudioBilling::FinancialAdjustment.sole.kind
    assert_equal "open", RecordingStudioBilling::ReconciliationIssue.find_by!(kind: "demo_provider_terms").state
    tax_states = RecordingStudioBilling::ReconciliationIssue.where("kind LIKE 'demo_tax_%'").order(:kind).map do |issue|
      issue.safe_payload.fetch("tax_state")
    end
    assert_equal %w[disabled pending unsupported], tax_states
    closed_period = RecordingStudioBilling::UsagePeriod.find_by!(usage_key: "demo_api_calls", state: "closed")
    assert_equal 40, RecordingStudioBilling::UsageCreditGrant.find_by!(source_key: "demo_usage_credit").remaining_quantity
    assert_equal "demo_usage_api_overage", closed_period.safe_metadata.fetch("overage_price_key")

    assert_no_difference -> { RecordingStudio::Recording.count } do
      assert_no_difference -> { Workspace.count } do
        assert_no_difference -> { AdminRoot.count } do
          assert_no_difference -> { RecordingStudioBilling::Account.count } do
            assert_no_difference -> { RecordingStudioBilling::BillingAdmin.count } do
                assert_no_difference -> { RecordingStudioBilling::ProviderAccount.count } do
                  assert_no_difference -> { RecordingStudioBilling::Product.count } do
                    assert_no_difference -> { RecordingStudioBilling::Price.count } do
                      assert_no_difference -> { RecordingStudioBilling::UsageUnit.count } do
                        assert_no_difference -> { RecordingStudioBilling::OveragePrice.count } do
                          load Rails.root.join("db/seeds.rb").to_s
                        end
                      end
                    end
                  end
                end
            end
          end
        end
      end
    end
    assert_nil Current.actor
  ensure
    Current.actor = nil
  end
end
