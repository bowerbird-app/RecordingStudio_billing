# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class PlansPageTest < Minitest::Test
  def test_draw_helper_registers_a_host_route
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw do
      draw_recording_studio_billing_plans path: "/pricing", as: :pricing
    end

    recognition = routes.recognize_path("/pricing")
    assert_equal "recording_studio_billing/plans", recognition[:controller]
    assert_equal "show", recognition[:action]
  end

  def test_plans_path_for_prefers_the_configured_host_helper
    root = Struct.new(:id).new("root-123")

    RecordingStudioBilling.configuration.plans_page_route_helper = :plans_path

    assert RecordingStudioBilling::PlansPage.configured?
    assert_includes RecordingStudioBilling::PlansPage.path_for(root), "root-123"
  end

  def test_plans_path_for_falls_back_to_engine_plan_route
    root = Struct.new(:id).new("root-123")

    RecordingStudioBilling.configuration.plans_page_route_helper = :missing_plans_path

    refute RecordingStudioBilling::PlansPage.configured?
    path = RecordingStudioBilling::PlansPage.path_for(root)

    assert_includes path, "/billing/plan"
    assert_includes path, "root-123"
  ensure
    RecordingStudioBilling.configuration.plans_page_route_helper = :plans_path
  end
end
