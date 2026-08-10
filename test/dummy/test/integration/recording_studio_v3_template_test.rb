# frozen_string_literal: true

require "test_helper"

class RecordingStudioV3TemplateTest < ActiveSupport::TestCase
  test "dummy app loads root switchable config and controller support" do
    assert_equal [ "all_workspaces" ], RecordingStudioRootSwitchable.configuration.scopes.keys
    assert_equal :application_layout, RecordingStudioRootSwitchable.configuration.layout
    assert_includes ApplicationController.ancestors, RecordingStudio::RootSwitchable::ControllerSupport
  end

  test "dummy app validates v3 recordable declarations" do
    assert RecordingStudio.validate_recordable_declarations!
    assert_equal [ "Workspace" ], RecordingStudio.root_recordable_types
    assert_equal [ "Workspace", "Folder" ], RecordingStudio.allowed_parent_types_for("Page")
  end

  test "dummy app schema excludes removed access control tables" do
    connection = ActiveRecord::Base.connection

    assert connection.column_exists?(:recording_studio_recordings, :root_recording_id)
    refute connection.table_exists?(:recording_studio_accesses)
    refute connection.table_exists?(:recording_studio_access_boundaries)
    refute connection.table_exists?(:recording_studio_device_sessions)
  end

  test "dummy seeds use v3 hierarchy idempotently and restore current actor" do
    Current.actor = nil

    load Rails.root.join("db/seeds.rb").to_s

    workspace = Workspace.find_by!(name: "Studio Workspace")
    accessible_workspace = Workspace.find_by!(name: "Client Workspace")
    private_workspace = Workspace.find_by!(name: "Private Workspace")
    folder = Folder.find_by!(name: "Product Docs")
    page = Page.find_by!(title: "Getting Started")
    root_recording = RecordingStudio::Recording.find_by!(recordable: workspace)
    accessible_root_recording = RecordingStudio::Recording.find_by!(recordable: accessible_workspace)
    private_root_recording = RecordingStudio::Recording.find_by!(recordable: private_workspace)
    folder_recording = RecordingStudio::Recording.find_by!(recordable: folder)
    page_recording = RecordingStudio::Recording.find_by!(recordable: page)

    assert_nil Current.actor
    assert_nil root_recording.parent_recording_id
    assert_nil accessible_root_recording.parent_recording_id
    assert_nil private_root_recording.parent_recording_id
    assert_equal root_recording, folder_recording.parent_recording
    assert_equal root_recording, folder_recording.root_recording
    assert_equal folder_recording, page_recording.parent_recording
    assert_equal root_recording, page_recording.root_recording
    assert_equal 3, Workspace.count

    assert_no_difference -> { User.count } do
      assert_no_difference -> { RecordingStudio::Recording.count } do
        load Rails.root.join("db/seeds.rb").to_s
      end
    end
    assert_nil Current.actor
  ensure
    Current.actor = nil
  end
end
