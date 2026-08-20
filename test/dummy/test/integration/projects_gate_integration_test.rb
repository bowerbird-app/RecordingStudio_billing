# frozen_string_literal: true

require "test_helper"

class ProjectsGateIntegrationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup do
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(1_208_120_201)")
    @locked = true
    load Rails.root.join("db/seeds.rb").to_s
    @user = User.find_by!(email: "admin@admin.com")
    sign_in @user
  end

  teardown do
    return unless @locked

    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(1_208_120_201)")
    @locked = false
  end

  test "projects page uses soft gate status and hard create enforcement" do
    root = RecordingStudio.root_recording_for(Workspace.find_by!(name: "Studio Workspace"))
    assert_equal 1, Project.for_root(root).count
    assert RecordingStudioBilling.gate_allowed?(root_recording: root, gate_key: "demo_projects")

    get projects_path
    assert_response :success
    assert_match(/Projects/, response.body)
    assert_match(/Starter project/, response.body)
    assert_match(/still add/, response.body)

    post projects_path, params: { project: { name: "Second project" } }
    assert_redirected_to projects_path
    follow_redirect!
    assert_match(/Second project/, response.body)
    assert_equal 2, Project.for_root(root).count

    post projects_path, params: { project: { name: "Blocked project" } }
    assert_redirected_to projects_path
    follow_redirect!
    assert_match(/limit reached/i, response.body)
    assert_equal 2, Project.for_root(root).count
    refute_includes response.body, "Blocked project"
  end
end
