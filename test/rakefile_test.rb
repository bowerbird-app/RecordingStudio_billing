# test/rakefile_test.rb
# frozen_string_literal: true

require "minitest/autorun"
require "rake"

Dir.chdir(File.expand_path("..", __dir__)) do
  load "Rakefile"
end

class RakefileTest < Minitest::Test
  def test_root_task_environment_does_not_inherit_database_routing
    assert_equal "app_test", ENV.fetch("DB_NAME", nil)
    assert_nil ENV.fetch("DATABASE_URL", nil)
  end

  def test_dummy_bundle_env_does_not_inherit_development_database_settings
    environment = Object.new.send(:dummy_bundle_env)

    assert_equal "test", environment.fetch("RAILS_ENV")
    assert_nil environment["DB_NAME"]
    assert_nil environment["DATABASE_URL"]
  end

  def test_dummy_migration_wrappers_only_reference_engine_migrations
    engine_versions = Dir[File.join(__dir__, "..", "db/migrate", "*.rb")].map do |path|
      File.basename(path).split("_", 2).first
    end
    dummy_versions = Dir[File.join(__dir__, "dummy/db/migrate", "*.rb")].map do |path|
      File.basename(path).split("_", 2).first
    end.intersection(engine_versions)

    assert_equal dummy_versions.sort, dummy_versions.uniq.sort
    assert_empty dummy_versions - engine_versions
  end
end
