# frozen_string_literal: true

require "test_helper"

class RecordingStudioV3TemplateTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  test "dummy app loads root switchable configuration and billing admin support" do
    assert_equal ["all_workspaces"], RecordingStudioRootSwitchable.configuration.scopes.keys
    assert_equal :application_layout, RecordingStudioRootSwitchable.configuration.layout
    assert_includes ApplicationController.ancestors, RecordingStudio::RootSwitchable::ControllerSupport
    assert_includes AdminRoot.ancestors, RecordingStudioBilling::BillingAdminSupport
    assert_equal %w[billing_commercial billing_financial billing_operations],
                 AdminRoot.recording_studio_admin_section_keys_for(nil, nil, nil)
  end

  test "billing admin definitions are registered at site scope" do
    section_keys = %w[billing_account_operations billing_commercial billing_financial billing_operations]
    screen_section_keys = %w[billing_commercial billing_financial billing_operations]
    operation_keys = RecordingStudioBilling::ADMIN_OPERATION_AREAS.keys.map(&:to_s)
    account_operation_keys = %w[billing_feature_overrides]
    site_operation_keys = operation_keys - account_operation_keys

    assert_equal section_keys, RecordingStudioAdmin.sections.keys.grep(/^billing_/).sort
    assert_equal (screen_section_keys + operation_keys).sort, RecordingStudioAdmin.screens.keys.grep(/^billing_/).sort
    assert_equal (screen_section_keys + operation_keys).sort, RecordingStudioAdmin.resources.keys.grep(/^billing_/).sort

    assert_equal :root, RecordingStudioAdmin.section_for("billing_account_operations").blast_radius
    screen_section_keys.each do |key|
      assert_equal :site, RecordingStudioAdmin.section_for(key).blast_radius
    end

    (screen_section_keys + site_operation_keys).each do |key|
      assert_equal :site, RecordingStudioAdmin.screen_for(key).blast_radius
      assert_equal :site, RecordingStudioAdmin.resource_for(key).blast_radius
    end
    account_operation_keys.each do |key|
      assert_equal :root, RecordingStudioAdmin.screen_for(key).blast_radius
      assert_equal :root, RecordingStudioAdmin.resource_for(key).blast_radius
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
    assert_equal ["Workspace"], RecordingStudio.allowed_parent_types_for("Project")
    assert_equal ["Workspace"], RecordingStudio.allowed_parent_types_for("RecordingStudioBilling::Account")
    assert_equal ["AdminRoot"], RecordingStudio.allowed_parent_types_for("RecordingStudioBilling::BillingAdmin")
  end

  test "dummy seeds create an idempotent credential-free demonstration catalogue" do
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(1_208_120_200)")
    Current.actor = nil

    load Rails.root.join("db/seeds.rb").to_s

    workspace = Workspace.find_by!(name: "Studio Workspace")
    admin_root = AdminRoot.find_by!(name: "Billing Administration")
    workspace_recording = RecordingStudio::Recording.find_by!(recordable: workspace)
    admin_root_recording = RecordingStudio::Recording.find_by!(recordable: admin_root)
    account_recording = RecordingStudio::Recording.find_by!(root_recording: workspace_recording,
                                parent_recording: workspace_recording,
                                recordable_type: "RecordingStudioBilling::Account")
    billing_admin_recording = RecordingStudio::Recording.find_by!(root_recording: admin_root_recording,
                                    parent_recording: admin_root_recording,
                                    recordable_type: "RecordingStudioBilling::BillingAdmin")
    account = account_recording.recordable
    billing_admin = billing_admin_recording.recordable
    catalogue = lambda do |model|
      model.where(id: RecordingStudio::Recording.where(root_recording: admin_root_recording,
                                                        recordable_type: model.name).select(:recordable_id))
    end

    assert_nil Current.actor
    assert_nil workspace_recording.parent_recording_id
    assert_nil admin_root_recording.parent_recording_id
    assert_equal workspace_recording, account_recording.parent_recording
    assert_equal admin_root_recording, billing_admin_recording.parent_recording
    assert_equal 1, Workspace.where(name: "Studio Workspace").count
    assert_equal 1, AdminRoot.where(name: "Billing Administration").count
    assert_equal "Studio Account", account.name
    assert_equal "billing", billing_admin.key
    assert_equal %w[demo_fake_provider demo_stripe_test_provider], catalogue.call(RecordingStudioBilling::ProviderAccount).order(:key).pluck(:key)
    provider = catalogue.call(RecordingStudioBilling::ProviderAccount).find_by!(key: "demo_fake_provider")
    assert_equal "fake", provider.adapter_key
    assert_equal({}, provider.configuration)
    stripe_provider = catalogue.call(RecordingStudioBilling::ProviderAccount).find_by!(key: "demo_stripe_test_provider")
    assert_equal "stripe", stripe_provider.adapter_key
    assert_equal({ "display_name" => "Stripe test" }, stripe_provider.configuration)
    assert_equal %w[demo_annual_plan demo_checkout_product demo_credit_pack demo_free_plan demo_monthly_plan demo_quantity_addon demo_usage_product], catalogue.call(RecordingStudioBilling::Product).order(:key).pluck(:key)
    assert_equal "service", catalogue.call(RecordingStudioBilling::Product).find_by!(key: "demo_usage_product").kind
    assert_equal "credit_pack", catalogue.call(RecordingStudioBilling::Product).find_by!(key: "demo_credit_pack").kind
    assert_equal 7, catalogue.call(RecordingStudioBilling::BillingOption).count
    assert_equal 14, catalogue.call(RecordingStudioBilling::BillingOption).find_by!(key: "demo_annual_plan_option").trial_days
    assert_equal "allowance", catalogue.call(RecordingStudioBilling::Feature).find_by!(
      key: "demo_api_calls",
      product_recording_id: catalogue.call(RecordingStudioBilling::Product).find_by!(key: "demo_usage_product").recording.id
    ).kind
    assert_equal %w[demo_api_call], catalogue.call(RecordingStudioBilling::UsageUnit).order(:key).pluck(:key)
    assert_equal %w[demo_api_calls], catalogue.call(RecordingStudioBilling::Meter).order(:key).pluck(:key)
    assert_equal %w[demo_usage_rates], catalogue.call(RecordingStudioBilling::RateCard).order(:key).pluck(:key)
    assert_equal %w[demo_api_call_conversion], catalogue.call(RecordingStudioBilling::Rate).order(:key).pluck(:key)
    assert_equal %w[demo_usage_costs], catalogue.call(RecordingStudioBilling::CostCard).order(:key).pluck(:key)
    assert_equal %w[demo_api_call_cost], catalogue.call(RecordingStudioBilling::CostRate).order(:key).pluck(:key)
    assert_equal %w[demo_usage_api_overage], catalogue.call(RecordingStudioBilling::OveragePrice).order(:key).pluck(:key)
    assert_equal "published", catalogue.call(RecordingStudioBilling::Price).find_by!(key: "demo_usage_us_price").state
    assert_equal "published", catalogue.call(RecordingStudioBilling::OveragePrice).find_by!(key: "demo_usage_api_overage").state
    assert_equal "published", catalogue.call(RecordingStudioBilling::Price).find_by!(key: "demo_monthly_plan_us_price").state
    market_prices = %w[demo_us_market demo_uk_market demo_it_market demo_de_market demo_global_market].to_h do |key|
      price = catalogue.call(RecordingStudioBilling::Price).find_by!(key: "#{key}_price")
      [key, [price.currency_code, price.amount_minor]]
    end
    assert_equal ["USD", 1_200], market_prices.fetch("demo_us_market")
    assert_equal ["GBP", 900], market_prices.fetch("demo_uk_market")
    assert_equal ["EUR", 1_000], market_prices.fetch("demo_it_market")
    assert_equal ["EUR", 1_100], market_prices.fetch("demo_de_market")
    assert_equal ["USD", 1_300], market_prices.fetch("demo_global_market")
    plan_amounts = %w[demo_free_plan demo_monthly_plan demo_annual_plan].map do |key|
      catalogue.call(RecordingStudioBilling::Price).find_by!(key: "#{key}_us_price").amount_minor
    end
    assert_equal [0, 4_900, 49_000], plan_amounts.sort
    monthly_it = catalogue.call(RecordingStudioBilling::Price).find_by!(key: "demo_monthly_plan_it_price")
    monthly_de = catalogue.call(RecordingStudioBilling::Price).find_by!(key: "demo_monthly_plan_de_price")
    assert_equal ["EUR", 4_500], [monthly_it.currency_code, monthly_it.amount_minor]
    assert_equal ["EUR", 4_700], [monthly_de.currency_code, monthly_de.amount_minor]
    refute_equal catalogue.call(RecordingStudioBilling::Price).find_by!(key: "demo_annual_plan_it_price").amount_minor,
                 catalogue.call(RecordingStudioBilling::Price).find_by!(key: "demo_annual_plan_de_price").amount_minor
    assert_equal "requires", catalogue.call(RecordingStudioBilling::ProductRule).find_by!(key: "demo_addon_requires_plan").rule_type
    assert_equal "published", catalogue.call(RecordingStudioBilling::PlanUpdate).find_by!(key: "demo_monthly_plan_review").state

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
                          assert_no_difference -> { RecordingStudioBilling::PlanUpdate.count } do
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
    end
    assert_nil Current.actor
  ensure
    Current.actor = nil
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(1_208_120_200)")
  end
end
