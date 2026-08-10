# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "generators/gem_template/install/install_generator"

class InstallGeneratorTest < Minitest::Test
  INSTALL_TEMPLATE_PATH = File.expand_path(
    "../lib/generators/gem_template/install/templates/INSTALL.md",
    __dir__
  )

  def with_temp_app
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app/assets/tailwind"))
      yield dir
    end
  end

  def build_generator(destination_root, options = {})
    GemTemplate::Generators::InstallGenerator.new(
      [],
      options,
      destination_root: destination_root
    )
  end

  def test_mount_engine_uses_configured_mount_path
    generator = build_generator("/tmp", mount_path: "/addons/recording")
    routes = []

    generator.stub(:route, ->(value) { routes << value }) do
      generator.mount_engine
    end

    assert_equal ["mount GemTemplate::Engine, at: \"/addons/recording\""], routes
  end

  def test_add_tailwind_source_injects_engine_and_flatpack_sources
    with_temp_app do |dir|
      css_path = File.join(dir, "app/assets/tailwind/application.css")
      File.write(css_path, "@import \"tailwindcss\";\n")

      generator = build_generator(dir)

      Rails.stub(:root, Pathname.new(dir)) do
        generator.stub(:say, nil) do
          generator.add_tailwind_source
        end
      end

      css = File.read(css_path)
      assert_tailwind_sources_present(css)
    end
  end

  def test_add_tailwind_source_does_not_duplicate_existing_entries
    with_temp_app do |dir|
      css_path = File.join(dir, "app/assets/tailwind/application.css")
      File.write(css_path, <<~CSS)
        @import "tailwindcss";
        @source "../../vendor/bundle/**/gem_template/app/views/**/*.erb";
        @source "../../../../../../usr/local/bundle/ruby/**/bundler/gems/gem_template-*/app/views/**/*.erb";
        @source "../../vendor/bundle/**/flatpack/app/components/**/*.{rb,erb}";
        @source "../../../../../../usr/local/bundle/ruby/**/bundler/gems/flatpack-*/app/components/**/*.{rb,erb}";
      CSS

      generator = build_generator(dir)

      Rails.stub(:root, Pathname.new(dir)) do
        generator.stub(:say, nil) do
          generator.add_tailwind_source
        end
      end

      css = File.read(css_path)
      assert_tailwind_sources_present(css)
      assert_tailwind_sources_count(css, 1)
    end
  end

  def test_add_tailwind_source_reports_missing_tailwind_config
    with_temp_app do |dir|
      FileUtils.rm_rf(File.join(dir, "app/assets/tailwind"))
      generator = build_generator(dir)
      messages = []

      Rails.stub(:root, Pathname.new(dir)) do
        generator.stub(:say, ->(message, color = nil) { messages << [message, color] }) do
          generator.add_tailwind_source
        end
      end

      assert_includes messages, ["Tailwind CSS not detected. Skipping Tailwind configuration.", :yellow]
      assert_includes messages, ["If you use Tailwind, add these lines to your Tailwind CSS config:", :yellow]
      tailwind_source_lines.each do |line|
        assert_includes messages, ["  #{line}", :yellow]
      end
    end
  end

  def test_add_tailwind_source_reports_manual_configuration_when_import_is_missing
    with_temp_app do |dir|
      css_path = File.join(dir, "app/assets/tailwind/application.css")
      File.write(css_path, "@source \"../local/**/*.erb\";\n")
      generator = build_generator(dir)
      messages = []

      Rails.stub(:root, Pathname.new(dir)) do
        generator.stub(:say, ->(message, color = nil) { messages << [message, color] }) do
          generator.add_tailwind_source
        end
      end

      assert_equal "@source \"../local/**/*.erb\";\n", File.read(css_path)
      assert_includes messages, ["Could not find @import \"tailwindcss\" in your Tailwind config.", :yellow]
      assert_includes messages, ["Please manually add these lines to your Tailwind CSS config:", :yellow]
      tailwind_source_lines.each do |line|
        assert_includes messages, ["  #{line}", :yellow]
      end
    end
  end

  def test_show_readme_displays_install_guide_for_invoke_behavior
    generator = build_generator("/tmp")
    shown_templates = []

    generator.stub(:behavior, :invoke) do
      generator.stub(:readme, ->(template) { shown_templates << template }) do
        generator.show_readme
      end
    end

    assert_equal ["INSTALL.md"], shown_templates
  end

  def test_install_guide_includes_migration_and_host_setup_steps
    install_guide = File.read(INSTALL_TEMPLATE_PATH)

    assert_includes install_guide, "bin/rails generate gem_template:migrations"
    assert_includes install_guide, "bin/rails db:migrate"
    assert_includes install_guide, "auth, layout, and current actor integration"
  end

  private

  def assert_tailwind_sources_present(css)
    tailwind_source_lines.each do |line|
      assert_includes css, line
    end
  end

  def assert_tailwind_sources_count(css, count)
    tailwind_source_lines.each do |line|
      assert_equal count, css.scan(line).size
    end
  end

  def tailwind_source_lines
    [
      '@source "../../vendor/bundle/**/gem_template/app/views/**/*.erb";',
      '@source "../../../../../../usr/local/bundle/ruby/**/bundler/gems/gem_template-*/app/views/**/*.erb";',
      '@source "../../vendor/bundle/**/flatpack/app/components/**/*.{rb,erb}";',
      '@source "../../../../../../usr/local/bundle/ruby/**/bundler/gems/flatpack-*/app/components/**/*.{rb,erb}";'
    ]
  end
end
