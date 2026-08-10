# frozen_string_literal: true

require "test_helper"

class GemTemplateTest < Minitest::Test
  def test_version_matches_release
    assert_equal "0.1.2", ::GemTemplate::VERSION
  end

  def test_engine_exists
    assert_kind_of Class, ::GemTemplate::Engine
  end

  def test_dummy_app_uses_flatpack_sidebar_layout
    layout_path = File.expand_path("dummy/app/views/layouts/flat_pack_sidebar.html.erb", __dir__)
    assert File.exist?(layout_path)

    application_controller_path = File.expand_path("dummy/app/controllers/application_controller.rb", __dir__)
    controller_source = File.read(application_controller_path)
    assert_includes controller_source, "flat_pack_sidebar"
  end

  def test_dummy_layouts_default_to_flatpack_rounded_theme
    application_layout = File.read(File.expand_path("dummy/app/views/layouts/application.html.erb", __dir__))
    sidebar_layout = File.read(File.expand_path("dummy/app/views/layouts/flat_pack_sidebar.html.erb", __dir__))

    assert_includes application_layout, '<html data-theme="rounded">'
    assert_includes sidebar_layout, '<html data-theme="rounded" class="h-full overflow-hidden overscroll-none">'
  end

  def test_dummy_tailwind_keeps_flatpack_theme_selection_in_flatpack
    tailwind_source = File.read(File.expand_path("dummy/app/assets/tailwind/application.css", __dir__))

    assert_includes tailwind_source, "../../../vendor/bundle/**/flatpack/app/components/**/*.{rb,erb}"
    assert_includes tailwind_source, "flatpack-*/app/components/**/*.{rb,erb}"
    assert_includes tailwind_source, "../../../vendor/bundle/**/recording_studio/app/views/**/*.erb"
    assert_includes tailwind_source, "recordingstudio-*/app/views/**/*.erb"
    refute_includes tailwind_source, "@theme"
    refute_includes tailwind_source, ":root {"
    refute_includes tailwind_source, "--color-fp-primary"
  end

  def test_recording_studio_keeps_strict_recordable_declarations_enabled
    initializer_path = File.expand_path("dummy/config/initializers/recording_studio.rb", __dir__)
    initializer_source = File.read(initializer_path)

    assert_includes initializer_source, "config.require_recordable_declarations = true"
    assert_includes initializer_source, "config.recordable_types = [ \"Workspace\", \"Folder\", \"Page\" ]"
    refute_includes initializer_source, "config.include_children"
    refute_includes initializer_source, "config.features."
  end

  def test_dummy_readme_explains_dummy_app_purpose
    readme_path = File.expand_path("dummy/README.md", __dir__)
    readme_source = File.read(readme_path)

    assert_includes readme_source, "This Rails app exists to validate the Recording Studio addon template"
    assert_includes readme_source, "/recording_studio"
    assert_includes readme_source, "redirects to `/`"
  end

  def test_dummy_home_page_uses_demo_title_only
    view_path = File.expand_path("dummy/app/views/home/index.html.erb", __dir__)
    view_source = File.read(view_path)

    assert_includes view_source, 'title: "Template Demo"'
    assert_includes view_source, 'subtitle: "This dummy app is the browser-facing demo surface for the template."'
    assert_includes view_source, "FlatPack::Card::Component"
    refute_includes view_source, 'title: "Demo"'
  end

  def test_dummy_docs_pages_use_minimal_flatpack_documentation_components
    docs_view_paths = Dir[File.expand_path("dummy/app/views/docs/*.html.erb", __dir__)].reject do |view_path|
      File.basename(view_path).start_with?("_")
    end
    refute_empty docs_view_paths

    docs_view_paths.each do |view_path|
      view_source = File.read(view_path)

      assert_includes view_source, "FlatPack::PageTitle::Component"
      refute_includes view_source, "FlatPack::Card::Component"
    end

    methods_view = File.read(File.expand_path("dummy/app/views/docs/methods.html.erb", __dir__))
    assert_includes methods_view, "FlatPack::SectionTitle::Component"
    assert_includes methods_view, "FlatPack::CodeBlock::Component"

    gem_views_view = File.read(File.expand_path("dummy/app/views/docs/gem_views.html.erb", __dir__))
    assert_includes gem_views_view, "FlatPack::Table::Component"
    refute_includes gem_views_view, "FlatPack::List::Component"

    recordable_types_view = File.read(File.expand_path("dummy/app/views/docs/recordable_types.html.erb", __dir__))
    assert_includes recordable_types_view, "FlatPack::List::Component"

    recordings_tree_view = File.read(File.expand_path("dummy/app/views/docs/recordings_tree.html.erb", __dir__))
    assert_includes recordings_tree_view, "FlatPack::Tree::Component"
    refute_includes recordings_tree_view, "Current structure"
    refute_includes recordings_tree_view, "This tree is generated from RecordingStudio::Recording records"
  end

  def test_dummy_recordings_tree_view_omits_structure_section_copy
    recordings_tree_view = File.read(File.expand_path("dummy/app/views/docs/recordings_tree.html.erb", __dir__))

    assert_includes recordings_tree_view, 'title: "Recordings tree"'
    assert_includes recordings_tree_view, "FlatPack::Tree::Component"
    recording_tree_partial = File.read(File.expand_path("dummy/app/views/docs/_recording_tree_node.html.erb", __dir__))
    assert_includes recording_tree_partial, "parent_builder.node"
    refute_includes recordings_tree_view, "Current structure"
    refute_includes recordings_tree_view, "This tree is generated from RecordingStudio::Recording records"
  end

  def test_dummy_sidebar_includes_recordings_tree_navigation
    sidebar_path = File.expand_path("dummy/app/views/layouts/flat_pack/_sidebar.html.erb", __dir__)
    sidebar_source = File.read(sidebar_path)

    assert_includes sidebar_source, 'label: "Recordable types"'
    assert_includes sidebar_source, "docs_recordable_types_path"
    assert_includes sidebar_source, 'label: "Recordings tree"'
    assert_includes sidebar_source, "docs_recordings_tree_path"
    refute_includes sidebar_source, 'label: "Recording Studio"'
    refute_includes sidebar_source, 'href: "/recording_studio"'
  end

  def test_dummy_sidebar_uses_supported_icons_for_install_and_methods
    sidebar_path = File.expand_path("dummy/app/views/layouts/flat_pack/_sidebar.html.erb", __dir__)
    sidebar_source = File.read(sidebar_path)

    assert_includes sidebar_source, 'label: "Install"'
    assert_includes sidebar_source, "icon: :arrow_down_tray"
    assert_includes sidebar_source, 'label: "Methods"'
    assert_includes sidebar_source, "icon: :code_bracket"
    refute_includes sidebar_source, "icon: :download"
    refute_includes sidebar_source, "icon: :code\n"
  end

  def test_dummy_top_nav_uses_center_slot_to_keep_avatar_right_aligned
    top_nav_path = File.expand_path("dummy/app/views/layouts/flat_pack/_top_nav.html.erb", __dir__)
    top_nav_source = File.read(top_nav_path)

    assert_includes top_nav_source, "nav.center"
    assert_includes top_nav_source, 'aria-hidden="true"'
  end

  def test_engine_does_not_ship_a_home_view
    view_path = File.expand_path("../app/views/gem_template/home/index.html.erb", __dir__)

    refute File.exist?(view_path)
  end
end
