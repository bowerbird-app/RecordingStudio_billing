# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../test_helper"
require_relative "../dummy/config/environment"

require "devise/test/integration_helpers"
require "rails/test_help"

class DocsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TEST_PASSWORD = "DocsTestPassword!2026"

  setup do
    @user = User.find_or_create_by!(email: "docs-test@example.com") do |user|
      user.password = TEST_PASSWORD
      user.password_confirmation = TEST_PASSWORD
    end

    sign_in @user
  end

  test "install page renders successfully" do
    get docs_install_path
    assert_response :success
    assert_select "h1", text: "Install"
    assert_includes response.body, "Step 1"
    assert_includes response.body, "Provide one section title for each step"
    assert_includes response.body, "# Put the step instruction here."
  end

  test "config page renders successfully" do
    get docs_config_path
    assert_response :success
    assert_select "h1", text: "Config"
    expected_placeholder = "Replace this placeholder with the configuration settings your generated gem exposes."

    assert_includes response.body, expected_placeholder
    assert_includes response.body, "# Add the config settings for the gem here."
  end

  test "recordable types page renders configured recordables dynamically" do
    summary_data = create_recordable_type_summary_data

    get docs_recordable_types_path
    response_text = response.body.gsub(/\s+/, " ").strip

    assert_response :success
    assert_select "h1", text: "Recordable types"
    assert_includes(
      response.body,
      "The list below comes from RecordingStudio.recordable_declarations and v3 parent/root introspection."
    )
    assert_includes response.body, "Workspace"
    assert_includes response.body, "Folder"
    assert_includes response.body, "Page"
    assert_includes response_text, "Root recordable"
    assert_includes response_text, "Child recordable"
    assert_includes response_text, "Allowed parents: Workspace, Folder"
    assert_includes response_text, summary_data[:workspace]
    assert_includes response_text, summary_data[:folder]
  end

  test "recordable types page includes dummy app defaults" do
    get docs_recordable_types_path

    assert_response :success
    assert_includes response.body, "Workspace"
    assert_includes response.body, "Folder"
    assert_includes response.body, "Page"
  end

  test "recordings tree page renders successfully" do
    workspace = Workspace.create!(name: "Tree Workspace")
    root_recording = RecordingStudio.root_recording_for(workspace)
    folder = Folder.create!(name: "Reference")
    folder_recording = record_child(folder, root_recording, root_recording)
    page = Page.create!(title: "API")
    record_child(page, root_recording, folder_recording)

    get docs_recordings_tree_path

    assert_response :success
    assert_select "h1", text: "Recordings tree"
    assert_includes response.body, "Workspace: Tree Workspace"
    assert_includes response.body, "Folder: Reference"
    assert_includes response.body, "Page: API"
    refute_includes response.body, "Access boundary"
    refute_includes response.body, "Access: Admin"
    assert_select "div[role='tree']", count: 1
    assert_select "[role='treeitem']", minimum: 3
    refute_includes response.body, "Current structure"
    refute_includes response.body, "This tree is generated from RecordingStudio::Recording records"
  end

  test "gem_views page renders successfully" do
    get docs_gem_views_path
    assert_response :success
    assert_select "h1", text: "Gem Views"
    assert_select "table", minimum: 1
    refute_includes response.body, "app/views/gem_template/home/index.html.erb"
  end

  test "methods page renders successfully" do
    get docs_methods_path
    assert_response :success
    assert_select "h1", text: "Methods"
    assert_includes response.body, "Document the public methods your addon exposes."
    assert_includes response.body, "Example method"
    assert_includes response.body, "recordingstudio_addon.example_method"
    assert_includes response.body, "# Explain what this method does before the example."
    assert_includes response.body, "Provide one section title and codeblock for each method"
  end

  test "sidebar includes documentation links" do
    get docs_install_path

    assert_select %(a[href="#{docs_install_path}"]), text: /Install/
    assert_select %(a[href="#{docs_config_path}"]), text: /Config/
    assert_select %(a[href="#{docs_recordable_types_path}"]), text: /Recordable types/
    assert_select %(a[href="#{docs_recordings_tree_path}"]), text: /Recordings tree/
    assert_select %(a[href="#{docs_gem_views_path}"]), text: /Gem Views/
    assert_select %(a[href="#{docs_methods_path}"]), text: /Methods/
  end

  private

  def create_recordable_type_summary_data
    workspace_recordings_before = RecordingStudio::Recording.where(recordable_type: "Workspace").count
    workspaces_before = Workspace.count
    folder_recordings_before = RecordingStudio::Recording.where(recordable_type: "Folder").count
    folders_before = Folder.count

    workspace = Workspace.create!(name: "Counted Workspace")
    2.times do
      RecordingStudio.root_recording_for(Workspace.create!(name: "Counted Workspace #{SecureRandom.hex(4)}"))
    end

    root_recording = RecordingStudio.root_recording_for(workspace)
    folder = Folder.create!(name: "Counted Folder")
    record_child(folder, root_recording, root_recording)

    {
      workspace: recordable_type_summary(
        workspace_recordings_before + 3,
        workspaces_before + 3
      ),
      folder: recordable_type_summary(
        folder_recordings_before + 1,
        folders_before + 1
      )
    }
  end

  def recordable_type_summary(recording_count, recordable_count)
    "#{ActionController::Base.helpers.pluralize(recording_count, 'recording')} point to this type " \
      "• #{ActionController::Base.helpers.pluralize(recordable_count, 'recordable')} in the database"
  end

  def record_child(recordable, root_recording, parent_recording)
    RecordingStudio.record!(
      action: "created",
      recordable: recordable,
      root_recording: root_recording,
      parent_recording: parent_recording
    ).recording
  end
end
