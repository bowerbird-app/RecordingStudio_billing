# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

class BillingAdminHubsTest < ActiveSupport::TestCase
  test "billing hubs expose widgets tables and inventory links" do
    RecordingStudioBilling::BillingAdminHubs::HIGH_SIGNAL_SCREEN_KEYS.each do |section_key, screen_keys|
      section = RecordingStudioAdmin.section_for(section_key)
      hub_screen = RecordingStudioAdmin.screen_for(section_key)
      widget_keys = screen_keys.map { |key| RecordingStudioBilling::BillingAdminHubs.widget_key_for(key) }

      assert_equal widget_keys, section.widget_keys
      expected_links = RecordingStudioBilling::BillingAdminHubs.inventory_screen_keys_for(section_key)
      expected_links += [RecordingStudioBilling::BillingAdminProductNew::SCREEN_KEY] if section_key == "billing_commercial"
      expected_links += [section_key]
      assert_equal expected_links, linked_screen_keys_for(section)
      assert_equal RecordingStudioBilling::BillingAdminHubs::HUB_TABLES.fetch(section_key).fetch(:title),
                   hub_screen.table_value.title_value
      refute_equal "Table data", hub_screen.table_value.title_value
      widget_keys.each do |widget_key|
        widget = RecordingStudioAdmin.widget_for(widget_key)
        assert widget
        assert_equal :list, widget.type
      end
    end
  end

  test "financial command widget rows keep type and state in the wrapping label" do
    spec = RecordingStudioBilling::BillingAdminHubs::WIDGET_SPECS.find do |entry|
      entry.fetch(:screen) == "billing_financial_commands"
    end
    context = Object.new
    def context.admin_screen_path(key) = "/admin/screens/#{key}"
    row = Struct.new(:command_type, :state).new("subscription_change", "requires_reconciliation")
    relation = [row]
    def relation.limit(*) = self

    items = RecordingStudioBilling::BillingAdminHubs.stub(:widget_scope, ->(*) { relation }) do
      RecordingStudioBilling::BillingAdminHubs.widget_items(spec, context)
    end

    assert_equal 1, items.size
    assert_equal "Plan change · Needs a look", items.first[:text]
    refute items.first.key?(:trailing)
    assert_equal "/admin/screens/billing_financial_commands", items.first[:href]
  end

  test "product and price widgets prefer human names and formatted money" do
    product = Struct.new(:name, :key, :kind).new("Starter", "stripe_test_monthly_plan", "plan")
    price = Struct.new(:amount_minor, :currency_code, :currency_exponent, :billing_option_recording).new(
      100, "USD", 2, nil
    )
    option = Struct.new(:product_recording).new(Struct.new(:recordable).new(product))
    price.billing_option_recording = Struct.new(:recordable).new(option)

    assert_equal "Starter",
                 RecordingStudioBilling::BillingAdminHubs.send(:widget_text, product, :product_name)
    assert_equal "Plan",
                 RecordingStudioBilling::BillingAdminHubs.send(:widget_trailing, product, :product_kind)
    assert_equal "Starter · $1",
                 RecordingStudioBilling::BillingAdminHubs.send(:widget_text, price, :price_offer)
    assert_equal "€470",
                 RecordingStudioBilling::DisplayFormatters.format_money(47_000, "EUR")
    assert_equal "26 Aug",
                 RecordingStudioBilling::DisplayFormatters.format_date(Time.utc(2026, 8, 26), now: Time.utc(2026, 8, 29))
  end

  test "manifest widget labels lead with product name and keep a short digest" do
    manifest = Struct.new(:canonical_data, :recording_snapshots, :used_at, :created_at, :manifest_digest).new(
      { "product" => { "key" => "demo_pro" } }, {}, Time.utc(2026, 8, 29), Time.utc(2026, 8, 29), "a4633aedffd3"
    )

    label = RecordingStudioBilling::BillingAdminHubs.stub(:name_from_product_key, ->(*) { "Pro" }) do
      RecordingStudioBilling::BillingAdminHubs.send(:manifest_offer_label, manifest)
    end

    assert_equal "Pro · 29 Aug · a4633a", label
    refute_equal "a4633aedffd3", label
  end

  test "plan update widget labels stay distinct when products match" do
    option = Struct.new(:product_recording).new(
      Struct.new(:recordable).new(Struct.new(:name, :key, :kind).new("Pro", "demo_pro", "plan"))
    )
    recording = Struct.new(:recordable).new(option)
    first = Struct.new(:billing_option_recording, :key, :effective_at, :created_at).new(
      recording, "demo_plan_update_uncertain", nil, Time.utc(2026, 8, 29)
    )
    second = Struct.new(:billing_option_recording, :key, :effective_at, :created_at).new(
      recording, "demo_plan_update_failed", nil, Time.utc(2026, 8, 29)
    )

    assert_equal "Pro · Uncertain",
                 RecordingStudioBilling::BillingAdminHubs.send(:widget_text, first, :plan_update_label)
    assert_equal "Pro · Failed",
                 RecordingStudioBilling::BillingAdminHubs.send(:widget_text, second, :plan_update_label)
  end

  test "operations hub kind column formats provider mismatch" do
    options = RecordingStudioBilling::BillingAdminHubs.hub_table_column_options("billing_operations", :kind)
    row = Struct.new(:kind).new("provider_result_mismatch")

    assert_equal "Provider mismatch", options.fetch(:value).call(row, nil)
  end

  test "inventory table columns and filters exist on their models" do
    RecordingStudioBilling::ADMIN_OPERATION_AREAS.each do |screen_key, definition|
      model = "RecordingStudioBilling::#{definition.fetch(:model)}".constantize
      record = model.new
      (definition.fetch(:columns) + definition.fetch(:filters)).uniq.each do |field|
        assert record.respond_to?(field), "#{screen_key} #{field}"
      end
    end
  end

  test "products inventory registers a primary New button to the Admin create screen" do
    screen = RecordingStudioAdmin.screen_for("billing_products")
    button = screen.buttons_value.find { |entry| entry.name == :new_product }

    assert button
    assert_equal "New", button.text
    assert_equal :primary, button.style

    context = Object.new
    def context.admin_screen_path(key) = "/admin/screens/#{key}"
    assert_equal "/admin/screens/billing_product_new", button.url.call(context)
    assert RecordingStudioAdmin.screen_for("billing_product_new")
    assert_equal %i[name key kind state],
                 RecordingStudioBilling::ADMIN_OPERATION_AREAS.fetch(:billing_products).fetch(:columns)
  end

  test "product create stays on the BillingAdmin parent and existing draft operation" do
    action = RecordingStudioAdmin.resource_for("billing_products").action_for(:create)
    context = Object.new
    def context.params = {}

    refute action.visible?(RecordingStudioBilling::Product.new, context)

    billing_admin = RecordingStudio::Recording.new
    billing_admin.recordable_type = "RecordingStudioBilling::BillingAdmin"
    assert action.visible?(billing_admin, context)

    parent_context = Object.new
    def parent_context.params = { "parent_recording_id" => "parent-1" }
    assert action.visible?(RecordingStudioBilling::Product.new, parent_context)

    create_context = Object.new
    def create_context.controller
      routes = Object.new
      def routes.recording_studio_billing_path = "/billing"
      Object.new.tap { |controller| controller.define_singleton_method(:main_app) { routes } }
    end

    def create_context.params = { "parent_recording_id" => "parent-1" }
    assert_includes action.url.call(billing_admin, create_context), "create_draft_product"
  end

  test "product create form posts to the mounted draft operation once" do
    context = Object.new
    def context.controller
      routes = Object.new
      def routes.recording_studio_billing_path = "/billing"
      Object.new.tap { |controller| controller.define_singleton_method(:main_app) { routes } }
    end

    url = RecordingStudioBilling::BillingAdminProductNew.mounted_operation_url(
      context,
      "/billing/admin/operations/create_draft_product?parent_recording_id=parent-1"
    )
    assert_equal "/billing/admin/operations/create_draft_product?parent_recording_id=parent-1", url

    relative = RecordingStudioBilling::BillingAdminProductNew.mounted_operation_url(
      context,
      "/admin/operations/create_draft_product?parent_recording_id=parent-1"
    )
    assert_equal "/billing/admin/operations/create_draft_product?parent_recording_id=parent-1", relative
  end

  test "catalogue key filters do not occupy the Admin screen route param" do
    RecordingStudioBilling::ADMIN_OPERATION_AREAS.each do |screen_key, definition|
      next unless definition.fetch(:filters).include?(:key)

      filter = RecordingStudioAdmin.screen_for(screen_key).filters.find { |entry| entry.key == :key }
      assert filter, screen_key
      assert_equal :catalogue_key, filter.param_key, screen_key
      refute_equal :key, filter.param_key, screen_key
    end
  end

  test "account billing operations is hidden on a site admin root" do
    section = RecordingStudioAdmin.section_for("billing_account_operations")

    refute section.visible_if.call(access_context_for(AdminRoot.new(name: "Site")))
    assert section.visible_if.call(access_context_for(Workspace.new(name: "Studio")))
  end

  private

  def linked_screen_keys_for(section)
    context = Object.new
    def context.admin_screen_path(key) = "/admin/screens/#{key}"

    section.links.filter_map do |link|
      resolved = link.resolve(context)
      next unless resolved

      resolved.url.to_s.delete_prefix("/admin/screens/")
    end
  end

  def access_context_for(recordable)
    recording = Struct.new(:recordable).new(recordable)
    context = Object.new
    context.define_singleton_method(:access_recording) { recording }
    context
  end
end
