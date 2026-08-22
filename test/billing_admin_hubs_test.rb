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
      assert_equal RecordingStudioBilling::BillingAdminHubs.inventory_screen_keys_for(section_key) + [section_key],
                   linked_screen_keys_for(section)
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
