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
      expected_links += ["/billing/admin/products/new"] if section_key == "billing_commercial"
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
    assert_equal "subscription_change · requires_reconciliation", items.first[:text]
    refute items.first.key?(:trailing)
    assert_equal "/admin/screens/billing_financial_commands", items.first[:href]
  end

  test "billing does not fork Admin screens show" do
    refute File.exist?(RecordingStudioBilling::Engine.root.join("app/views/recording_studio_admin/screens/show.html.erb"))
    refute Dir.exist?(RecordingStudioBilling::Engine.root.join("app/views/recording_studio_admin"))
    refute RecordingStudioAdmin.screen_for("billing_product_new")

    admin_show = RecordingStudioAdmin::Engine.root.join("app/views/recording_studio_admin/screens/show.html.erb")
    assert_includes File.read(admin_show), "FlatPack::ButtonGroup::Component"
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

  test "products inventory registers a primary New button to the billing create page" do
    screen = RecordingStudioAdmin.screen_for("billing_products")
    button = screen.buttons_value.find { |entry| entry.name == :new_product }

    assert button
    assert_equal "New", button.text
    assert_equal :primary, button.style

    context = Object.new
    def context.admin_screen_path(key) = "/admin/screens/#{key}"

    def context.controller
      routes = Object.new
      def routes.recording_studio_billing_path = "/billing"
      Object.new.tap { |controller| controller.define_singleton_method(:main_app) { routes } }
    end

    url = with_stubbed_new_product_parent { button.url.call(context) }
    assert_includes url, "/billing/admin/products/new"
    assert_includes url, "parent_recording_id=parent-1"
    assert_includes url, "return_to="
    assert_includes url, "billing_products"
    refute RecordingStudioAdmin.screen_for("billing_product_new")
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

    def context.controller
      routes = Object.new
      def routes.recording_studio_billing_path = "/billing"
      Object.new.tap { |controller| controller.define_singleton_method(:main_app) { routes } }
    end

    section.links.filter_map do |link|
      resolved = link.resolve(context)
      next unless resolved

      resolved.url.to_s.split("?").first.delete_prefix("/admin/screens/")
    end
  end

  def with_stubbed_new_product_parent
    parent = Struct.new(:id).new("parent-1")
    RecordingStudioBilling::BillingAdminProductNew.stub(:billing_admin_recording_for, parent) { yield }
  end

  def access_context_for(recordable)
    recording = Struct.new(:recordable).new(recordable)
    context = Object.new
    context.define_singleton_method(:access_recording) { recording }
    context
  end
end
