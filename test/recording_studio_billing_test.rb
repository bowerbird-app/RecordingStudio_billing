# frozen_string_literal: true

require "test_helper"

class RecordingStudioBillingTest < Minitest::Test
  def test_version_matches_the_initial_billing_foundation_release
    assert_equal "0.1.2", RecordingStudioBilling::VERSION
  end

  def test_dummy_home_explains_the_phase_one_boundary
    view = File.read(File.expand_path("dummy/app/views/home/index.html.erb", __dir__))

    assert_includes view, 'title: "Recording Studio Billing"'
    assert_includes view, "Stripe as the default provider"
    assert_includes view, "Commercial billing behavior intentionally starts in a later phase."
    assert_includes view, "FlatPack::Card::Component"
  end

  def test_dummy_keeps_the_flatpack_rounded_theme
    layout = File.read(File.expand_path("dummy/app/views/layouts/flat_pack_sidebar.html.erb", __dir__))

    assert_includes layout, '<html data-theme="rounded">'
    assert_includes layout, "FlatPack::SidebarLayout::Component"
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
  end
end
