# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

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

  def test_builtin_stripe_registration_is_idempotent_when_called_directly
    configuration = RecordingStudioBilling.configuration
    configuration.provider_registry.reset!

    2.times { RecordingStudioBilling.register_builtin_providers! }

    assert_equal ["stripe"], configuration.provider_registry.keys
    assert_instance_of RecordingStudioBilling::StripeAdapter, RecordingStudioBilling.provider_adapter(:stripe)
  end

  def test_prepare_callbacks_restore_exactly_one_built_in_stripe_adapter
    configuration = RecordingStudioBilling.configuration
    configuration.provider_registry.reset!

    2.times { Rails.application.reloader.prepare! }

    assert_equal ["stripe"], configuration.provider_registry.keys
    assert_instance_of RecordingStudioBilling::StripeAdapter, RecordingStudioBilling.provider_adapter(:stripe)
  ensure
    configuration&.reset_registries!
  end

  def test_customer_billing_prefers_recording_studio_default_layout
    controller = RecordingStudioBilling::ApplicationController.new
    request = ActionDispatch::TestRequest.create
    request.format = :html
    controller.set_request!(request)

    assert_equal "recording_studio/default_layout", controller.send(:billing_host_layout)
  end

  def test_plans_page_uses_recording_studio_default_layout_only
    controller = RecordingStudioBilling::PlansApplicationController.new
    request = ActionDispatch::TestRequest.create
    request.format = :html
    controller.set_request!(request)

    assert_equal "recording_studio/default_layout", controller.send(:plans_host_layout)
  end

  def test_engine_packages_the_stripe_checkout_module_for_host_asset_pipelines
    assert_includes Rails.application.config.assets.precompile, "recording_studio_billing/stripe_checkout.js"
    assert_includes RecordingStudioBilling::Engine.paths["app/assets"].paths.map(&:to_s),
                    RecordingStudioBilling::Engine.root.join("app/assets").to_s
  end
end
