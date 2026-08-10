# frozen_string_literal: true

require "test_helper"

class EngineTest < Minitest::Test
  def test_engine_isolates_the_billing_namespace
    assert_equal "recording_studio_billing", RecordingStudioBilling::Engine.engine_name
  end

  def test_register_capabilities_declares_billing_children
    original_recording_studio = Object.const_get(:RecordingStudio) if Object.const_defined?(:RecordingStudio, false)
    Object.send(:remove_const, :RecordingStudio) if original_recording_studio
    recording_studio = Module.new do
      class << self
        attr_reader :registrations

        def register_capability(name, **options)
          (@registrations ||= {})[name] = options
        end
      end
    end
    Object.const_set(:RecordingStudio, recording_studio)

    RecordingStudioBilling.register_capabilities!

    assert_equal "RecordingStudioBilling::Account",
                 recording_studio.registrations.dig(:billing, :child_recordables)
    assert_equal "RecordingStudioBilling::BillingAdmin",
                 recording_studio.registrations.dig(:billing_admin, :child_recordables)
  ensure
    Object.send(:remove_const, :RecordingStudio) if Object.const_defined?(:RecordingStudio, false)
    Object.const_set(:RecordingStudio, original_recording_studio) if original_recording_studio
  end
end
