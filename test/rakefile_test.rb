# test/rakefile_test.rb
# frozen_string_literal: true

require "minitest/autorun"
require "rake"

load File.expand_path("../Rakefile", __dir__)

class RakefileTest < Minitest::Test
  def test_dummy_bundle_env_does_not_inherit_development_database_settings
    environment = Object.new.send(:dummy_bundle_env)

    assert_equal "test", environment.fetch("RAILS_ENV")
    assert_nil environment["DB_NAME"]
    assert_nil environment["DATABASE_URL"]
  end
end
