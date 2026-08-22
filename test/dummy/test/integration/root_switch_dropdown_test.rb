# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class RootSwitchDropdownTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "home page uses default layout without sign-out or root-switch chrome" do
    user = User.find_or_create_by!(email: "root-switch-test@example.com") do |record|
      record.password = "Password123!"
      record.password_confirmation = "Password123!"
    end

    sign_in user

    workspace = Workspace.create!(name: "Dropdown Workspace")
    admin_root = AdminRoot.create!(name: "Dropdown Administration")
    workspace_recording = RecordingStudio.root_recording_for(workspace)
    admin_root_recording = RecordingStudio.root_recording_for(admin_root)
    bootstrap_owner!(workspace_recording, user)
    bootstrap_owner!(admin_root_recording, user)

    get root_path

    assert_response :success
    assert_includes response.body, 'data-recording-studio-default-layout="true"'
    assert_includes response.body, 'data-theme="rounded"'
    refute_includes response.body, "flat-pack--sidebar-layout"
    refute_includes response.body, "data-billing-layout"
    refute_includes response.body, "Sign out"
    refute_includes response.body, "Sign in"
    refute_includes response.body, "Login"
    refute_includes response.body, "root_switch"
    refute_includes response.body, workspace.name
    refute_includes response.body, admin_root.name
  end

  test "root switch page renders with the default layout" do
    user = User.find_or_create_by!(email: "root-switch-page-test@example.com") do |record|
      record.password = "Password123!"
      record.password_confirmation = "Password123!"
    end

    sign_in user

    workspace = Workspace.create!(name: "Switch Page Workspace")
    workspace_recording = RecordingStudio.root_recording_for(workspace)
    bootstrap_owner!(workspace_recording, user)

    admin_root = AdminRoot.create!(name: "Switch Page Administration")
    admin_root_recording = RecordingStudio.root_recording_for(admin_root)
    bootstrap_owner!(admin_root_recording, user)

    get "/recording_studio_root_switchable/v1/root_switch?scope=all_workspaces"

    assert_response :success
    assert_includes response.body, workspace.name
    assert_includes response.body, admin_root.name
    assert_includes response.body, 'data-recording-studio-default-layout="true"'
    assert_includes response.body, 'data-theme="rounded"'
    refute_includes response.body, "flat-pack--sidebar-layout"
    refute_includes response.body, "data-billing-layout"
    refute_includes response.body, "Sign out"
  end

  test "switching returns to the current page when it is a valid internal route" do
    user = User.find_or_create_by!(email: "root-switch-redirect-test@example.com") do |record|
      record.password = "Password123!"
      record.password_confirmation = "Password123!"
    end

    sign_in user

    source_workspace = Workspace.create!(name: "Source Workspace")
    target_workspace = Workspace.create!(name: "Target Workspace")
    target_root_recording = RecordingStudio.root_recording_for(target_workspace)
    source_root_recording = RecordingStudio.root_recording_for(source_workspace)
    bootstrap_owner!(source_root_recording, user)
    bootstrap_owner!(target_root_recording, user)

    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces",
      root_switch: {
        root_recording_id: target_root_recording.id,
        return_to: "/"
      }
    }

    assert_redirected_to "/"
  end

  test "switching falls back to home when return_to is not a valid internal route" do
    user = User.find_or_create_by!(email: "root-switch-fallback-test@example.com") do |record|
      record.password = "Password123!"
      record.password_confirmation = "Password123!"
    end

    sign_in user

    source_workspace = Workspace.create!(name: "Fallback Source Workspace")
    target_workspace = Workspace.create!(name: "Fallback Target Workspace")
    target_root_recording = RecordingStudio.root_recording_for(target_workspace)
    source_root_recording = RecordingStudio.root_recording_for(source_workspace)
    bootstrap_owner!(source_root_recording, user)
    bootstrap_owner!(target_root_recording, user)

    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces",
      root_switch: {
        root_recording_id: target_root_recording.id,
        return_to: "/not-a-real-route"
      }
    }

    assert_redirected_to "/"
  end

  private

  def bootstrap_owner!(recording, actor)
    result = RecordingStudioAccessible.bootstrap_owner_access!(recording:, actor:)
    raise result.error unless result.success?
  end
end
