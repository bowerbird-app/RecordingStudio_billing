# frozen_string_literal: true

require "test_helper"

class RecordingStudioBillingTest < Minitest::Test
  def test_version_matches_the_current_release
    assert_equal "0.7.0", RecordingStudioBilling::VERSION
  end

  def test_dummy_home_uses_default_layout_entry_buttons
    view = File.read(File.expand_path("dummy/app/views/home/index.html.erb", __dir__))

    assert_includes view, 'title: "Recording Studio Billing"'
    assert_includes view, "explicit adapter registration"
    assert_includes view, 'dummy_page_nav(title: "Billing demo")'
    assert_includes view, 'href: "/billing"'
    assert_includes view, 'href: "/plans"'
    refute_includes view, "Phase 1 boundary"
    refute_includes view, "flat_pack_sidebar"
  end

  def test_customer_sidebar_uses_flatpack_text_api
    sidebar = File.read(File.expand_path("../app/components/recording_studio_billing/customer_sidebar_component.html.erb", __dir__))

    assert_includes sidebar, "title: \"Billing\""
    assert_includes sidebar, "text: item.fetch(:label)"
    refute_includes sidebar, "label: \"Billing\""
    refute_includes sidebar, "label: item.fetch(:label)"
  end

  def test_dummy_does_not_ship_a_sidebar_shell
    dummy_layouts = File.expand_path("dummy/app/views/layouts", __dir__)

    refute File.exist?(File.join(dummy_layouts, "flat_pack_sidebar.html.erb"))
    refute File.exist?(File.join(dummy_layouts, "recording_studio/default_layout.html.erb"))
    refute File.exist?(File.join(dummy_layouts, "flat_pack/_sidebar.html.erb"))

    application = File.read(File.join(dummy_layouts, "application.html.erb"))
    assert_includes application, '<html data-theme="rounded">'
    refute_includes application, "Sign in"
    refute_includes application, "Login"
    refute_includes application, "FlatPack::SidebarLayout::Component"
  end

  def test_dummy_sql_structure_preserves_billing_integrity_objects
    structure_path = File.expand_path("dummy/db/structure.sql", __dir__)
    schema_path = File.expand_path("dummy/db/schema.rb", __dir__)
    structure = File.read(structure_path)

    refute File.exist?(schema_path)
    assert_includes structure, "CREATE FUNCTION public.rs_billing_protect_commercial_history()"
    assert_includes structure, "CREATE UNIQUE INDEX idx_rs_billing_one_account_per_root"
    assert_includes structure, "CREATE UNIQUE INDEX idx_rs_billing_one_admin_per_root"
    assert_includes structure,
                    "rs_billing_protect_commercial_history('RecordingStudioBilling::Price')"
    assert_includes structure, "DEFAULT 'market'::character varying"
    assert_includes structure, "send_invoice"
    assert_includes structure, "requires_restart"
    refute_match(/scope\)::text = 'default'/, structure)
    refute_includes structure, "('20260810000000')"
    assert_includes structure, "('20260816000001')"
    assert_includes structure, "('20260817000001')"
    assert_includes structure, "CREATE TABLE public.recording_studio_accesses"
  end
end
