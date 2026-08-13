# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

# The engine tests always use the dummy application's isolated test database.
# Never let a shell-level development connection redirect the test subprocess.
ENV.delete("DATABASE_URL")
ENV["DB_NAME"] = "app_test"

DUMMY_TEST_FILES = [
  File.expand_path("test/recording_studio_v3_test.rb", __dir__),
  File.expand_path("test/commercial_delivery_test.rb", __dir__),
  File.expand_path("test/financial_command_test.rb", __dir__),
  File.expand_path("test/provider_tax_contract_test.rb", __dir__)
].freeze
DUMMY_GEMFILE = File.expand_path("test/dummy/Gemfile", __dir__)
DUMMY_APP_ROOT = File.expand_path("test/dummy", __dir__)
TEST_ROOT = File.expand_path("test", __dir__)
ROOT_TEST_EXCLUSIONS = %w[
  test/dummy/**/*_test.rb
  test/commercial_delivery_test.rb
  test/financial_command_test.rb
  test/provider_tax_contract_test.rb
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

Rake::TestTask.new(:root_test_files) do |t|
  t.libs << "test"
  t.test_files = []
  t.verbose = false
end

namespace :test do
  task :prepare_database do
    Dir.chdir(DUMMY_APP_ROOT) do
      env = dummy_bundle_env
      run_command!(env, "bundle", "exec", "bin/rails", "db:create")
      run_command!(env, "bundle", "exec", "bin/rails", "db:prepare")
    end
  end
end

task test: "test:prepare_database" do
  root_env = {
    "RAILS_ENV" => "test",
    "DB_NAME" => "app_test",
    "DATABASE_URL" => nil,
    "BUNDLE_GEMFILE" => File.expand_path("Gemfile", __dir__)
  }
  FileList["test/**/*_test.rb"].exclude(*ROOT_TEST_EXCLUSIONS).each do |test_file|
    run_command!(root_env, "bundle", "exec", "ruby", "-I#{TEST_ROOT}", test_file)
  end
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

      run_command!(env, "bundle", "exec", "bin/rails", "db:environment:set", "RAILS_ENV=test")
      run_command!(env, "bundle", "exec", "bin/rails", "db:drop")
      run_command!(env, "bundle", "exec", "bin/rails", "db:create")
      run_command!(env, "bundle", "exec", "bin/rails", "db:migrate")
      run_command!(env, "bundle", "exec", "bin/rails", "db:schema:dump")
      run_command!(env, "bundle", "exec", "bin/rails", "db:seed")
      run_command!(env, "bundle", "exec", "bin/rails", "test")
      DUMMY_TEST_FILES.each do |test_file|
        run_command!(env, "bundle", "exec", "ruby", "-I#{TEST_ROOT}", test_file)
      end
    end
  end

  desc "Run gem and dummy app tests"
  task all: %i[dummy test]
end

namespace :app do
  desc "Run all tests for the gem"
  task test: "test:all"
end

task default: :test
