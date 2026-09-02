# frozen_string_literal: true

require "test_helper"

class RecordingStudioBillingTest < Minitest::Test
  def test_version_matches_the_current_release
    assert_equal "0.9.6", RecordingStudioBilling::VERSION
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
    refute File.exist?(File.join(dummy_layouts, "flat_pack/_sidebar.html.erb"))

    default_layout = File.read(File.join(dummy_layouts, "recording_studio/default_layout.html.erb"))
    assert_includes default_layout, '<html data-theme="'
    refute_includes default_layout, "flat_pack_sidebar"
    refute_includes default_layout, "Sign out"
    refute_includes default_layout, "recording_studio_root_switch_dropdown"

    application = File.read(File.join(dummy_layouts, "application.html.erb"))
    assert_includes application, '<html data-theme="rounded">'
    refute_includes application, "Sign in"
    refute_includes application, "Login"
    refute_includes application, "FlatPack::SidebarLayout::Component"

    helper = File.read(File.expand_path("dummy/app/helpers/application_helper.rb", __dir__))
    refute_includes helper, "recording_studio_page_nav_right"
    refute_includes helper, "recording_studio_root_switch_dropdown"
    refute_includes helper, "Sign out"
    refute_includes helper, "Sign in"
  end

  def test_dummy_runs_flatpack_rounded_button_rebinds
    spec = Bundler.definition.specs["flat_pack"].first
    assert_operator Gem::Version.new(spec.version.to_s), :>=, Gem::Version.new("0.1.135")

    css = File.read(File.join(spec.full_gem_path, "app/assets/stylesheets/flat_pack/variables.css"))
    assert_includes css, "--color-primary: oklch(0.3211 0 0)"
    assert_includes css, "--button-primary-background-color: var(--color-primary)"
    assert_includes css, "--button-border-radius: var(--radius-md)"
    assert_operator css.scan('[data-theme="rounded"]').size, :>=, 2
    assert_match(/\[data-theme="rounded"\][^{]*\{[^}]*--button-border-radius: var\(--radius-md\)/m, css)
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
    assert_includes structure, "('20260822000001')"
    assert_includes structure, "('20260901000001')"
    assert_includes structure, "CREATE UNIQUE INDEX idx_rs_billing_invoice_command"
    assert_includes structure, "recording_studio_billing_products"
    assert_match(/CREATE TABLE public\.recording_studio_billing_products[\s\S]*name character varying NOT NULL/, structure)
    assert_match(/CREATE TABLE public\.recording_studio_billing_billing_options[\s\S]*name character varying NOT NULL/, structure)
    assert_includes structure, "CREATE TABLE public.recording_studio_accesses"
  end
end
