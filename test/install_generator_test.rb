# frozen_string_literal: true

require "test_helper"
require "generators/recording_studio_billing/install/install_generator"

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
end
