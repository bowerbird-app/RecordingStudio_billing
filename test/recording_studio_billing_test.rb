# frozen_string_literal: true

require "test_helper"

class RecordingStudioBillingTest < Minitest::Test
  def test_version_matches_the_current_release
    assert_equal "0.2.0", RecordingStudioBilling::VERSION
  end

  def test_dummy_home_keeps_only_the_billing_title_and_subtitle
    view = File.read(File.expand_path("dummy/app/views/home/index.html.erb", __dir__))

    assert_includes view, 'title: "Recording Studio Billing"'
    assert_includes view, "explicit adapter registration"
    refute_includes view, "FlatPack::Card::Component"
    refute_includes view, "Phase 1 boundary"
  end

  def test_dummy_sidebar_mounts_the_gem_customer_sidebar
    sidebar = File.read(File.expand_path("dummy/app/views/layouts/flat_pack/_sidebar.html.erb", __dir__))

    assert_includes sidebar, "RecordingStudioBilling::CustomerSidebarComponent"
    refute_includes sidebar, 'label: "Billing"'
  end

  def test_dummy_keeps_the_flatpack_rounded_theme
    sidebar = File.read(File.expand_path("dummy/app/views/layouts/flat_pack_sidebar.html.erb", __dir__))
    default_layout = File.read(
      File.expand_path("dummy/app/views/layouts/recording_studio/default_layout.html.erb", __dir__)
    )

    [sidebar, default_layout].each do |layout|
      assert_includes layout, '<html data-theme="rounded"'
      assert_includes layout, "FlatPack::SidebarLayout::Component"
      assert_includes layout, "side: :left"
      assert_includes layout, 'stylesheet_link_tag "flat_pack/application"'
      assert_match(/data-billing-layout="(flat-pack-sidebar|recording-studio-default)"/, layout)
    end
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
