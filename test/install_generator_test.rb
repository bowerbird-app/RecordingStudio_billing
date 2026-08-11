# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"
require "generators/recording_studio_billing/install/install_generator"
require "generators/recording_studio_billing/migrations/migrations_generator"

class InstallGeneratorTest < Minitest::Test
  def test_mount_engine_uses_the_billing_namespace_and_default_path
    generator = RecordingStudioBilling::Generators::InstallGenerator.new([], {}, destination_root: "/tmp")
    routes = []

    generator.stub(:route, ->(value) { routes << value }) { generator.mount_engine }

    assert_equal ['mount RecordingStudioBilling::Engine, at: "/recording_studio_billing"'], routes
  end

  def test_tailwind_sources_reference_the_renamed_engine
    generator = RecordingStudioBilling::Generators::InstallGenerator.new([], {}, destination_root: "/tmp")

    assert_includes generator.send(:tailwind_source_lines),
                    '@source "../../vendor/bundle/**/recording_studio_billing/app/views/**/*.erb";'
  end

  def test_sql_schema_format_configuration_is_idempotent
    Dir.mktmpdir do |destination_root|
      application_path = File.join(destination_root, "config/application.rb")
      FileUtils.mkdir_p(File.dirname(application_path))
      File.write(application_path, <<~RUBY)
        module Dummy
          class Application < Rails::Application
          end
        end
      RUBY
      generator = RecordingStudioBilling::Generators::InstallGenerator.new([], {}, destination_root:)

      2.times { generator.configure_sql_schema_format }

      application = File.read(application_path)
      assert_equal 1, application.scan("config.active_record.schema_format = :sql").count
    end
  end

  def test_migration_generator_preserves_canonical_engine_versions_and_order
    Dir.mktmpdir do |destination_root|
      generator = RecordingStudioBilling::Generators::MigrationsGenerator.new([], {}, destination_root:)

      generator.copy_migrations

      expected = Dir.glob(File.expand_path("../db/migrate/*.rb", __dir__)).map { |path| File.basename(path) }.sort
      installed = Dir.glob(File.join(destination_root, "db/migrate/*.rb")).map { |path| File.basename(path) }.sort
      assert_equal expected, installed
    end
  end

  def test_migration_generator_rejects_a_host_timestamp_collision
    Dir.mktmpdir do |destination_root|
      migrations = File.join(destination_root, "db/migrate")
      FileUtils.mkdir_p(migrations)
      File.write(File.join(migrations, "20260810000000_create_host_table.rb"), "class CreateHostTable; end\n")
      generator = RecordingStudioBilling::Generators::MigrationsGenerator.new([], {}, destination_root:)

      error = assert_raises(Thor::Error) { generator.copy_migrations }

      assert_match(/20260810000000 is already used/, error.message)
    end
  end
end
