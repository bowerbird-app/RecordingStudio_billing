# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

DUMMY_TEST_FILES = [
  File.expand_path("test/recording_studio_v3_test.rb", __dir__),
  File.expand_path("test/commercial_delivery_test.rb", __dir__),
  File.expand_path("test/financial_command_test.rb", __dir__)
].freeze
DUMMY_GEMFILE = File.expand_path("test/dummy/Gemfile", __dir__)
DUMMY_APP_ROOT = File.expand_path("test/dummy", __dir__)
TEST_ROOT = File.expand_path("test", __dir__)
ROOT_TEST_EXCLUSIONS = %w[
  test/dummy/**/*_test.rb
  test/commercial_delivery_test.rb
  test/financial_command_test.rb
  test/recording_studio_v3_test.rb
  test/rename_verification_test.rb
].freeze
DUMMY_BUNDLE_CLEARED_ENV = {
  "BUNDLE_APP_CONFIG" => nil,
  "BUNDLE_BIN_PATH" => nil,
  "BUNDLE_GEMFILE" => DUMMY_GEMFILE,
  "BUNDLE_LOCKFILE" => nil,
  "BUNDLER_SETUP" => nil,
  "BUNDLER_VERSION" => nil,
  # DB_NAME and DATABASE_URL can point at a developer's database. The dummy
  # app's test configuration defaults to its isolated app_test database.
  "DB_NAME" => nil,
  "DATABASE_URL" => nil,
  "RUBYLIB" => nil,
  "RUBYOPT" => nil
}.freeze

def run_command!(env, *command)
  return if Bundler.with_unbundled_env { system(env, *command) }

  raise "Command failed (#{Process.last_status.exitstatus}): #{command.join(' ')}"
end

def dummy_bundle_env
  dummy_bundle_base_env.merge(DUMMY_BUNDLE_CLEARED_ENV).tap do |env|
    env["BUNDLE_PATH"] = ENV["BUNDLE_PATH"] if ENV["BUNDLE_PATH"]
  end
end

def dummy_bundle_base_env
  {
    "BUNDLE_GEMFILE" => DUMMY_GEMFILE,
    "DISABLE_SIMPLECOV" => "true",
    "RAILS_ENV" => "test"
  }
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude(*ROOT_TEST_EXCLUSIONS)
  t.verbose = false
end

namespace :test do
  desc "Run rename verification tests to validate gem naming consistency"
  task :rename_verification do
    ruby "test/rename_verification_test.rb", verbose: true
  end

  desc "Run rename verification tests in verbose mode"
  task :rename_verification_verbose do
    ruby "test/rename_verification_test.rb", "--verbose", verbose: true
  end

  desc "Run dummy app integration tests under the dummy app bundle"
  task :dummy do
    Dir.chdir(DUMMY_APP_ROOT) do
      env = dummy_bundle_env

      run_command!(env, "bundle", "exec", "bin/rails", "db:drop", "db:create", "db:migrate")
      run_command!(env, "bundle", "exec", "bin/rails", "test")
      DUMMY_TEST_FILES.each do |test_file|
        run_command!(env, "bundle", "exec", "ruby", "-I#{TEST_ROOT}", test_file)
      end
    end
  end

  desc "Run gem and dummy app tests"
  task all: %i[test dummy]
end

namespace :app do
  desc "Run all tests for the gem"
  task test: "test:all"
end

task default: :test
