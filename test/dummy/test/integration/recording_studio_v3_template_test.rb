# frozen_string_literal: true

require "test_helper"

class RecordingStudioV3TemplateTest < ActiveSupport::TestCase
  test "dummy app loads root switchable configuration and billing admin support" do
    assert_equal ["all_workspaces"], RecordingStudioRootSwitchable.configuration.scopes.keys
    assert_equal :application_layout, RecordingStudioRootSwitchable.configuration.layout
    assert_includes ApplicationController.ancestors, RecordingStudio::RootSwitchable::ControllerSupport
    assert_includes AdminRoot.ancestors, RecordingStudioBilling::BillingAdminSupport
    assert_equal ["billing"], AdminRoot.recording_studio_admin_section_keys_for(nil, nil, nil)
  end

  test "dummy app validates the billing recordable hierarchy" do
    assert RecordingStudio.validate_recordable_declarations!
    assert_equal %w[AdminRoot Workspace], RecordingStudio.root_recordable_types.sort
    assert_equal ["Workspace"], RecordingStudio.allowed_parent_types_for("RecordingStudioBilling::Account")
    assert_equal ["AdminRoot"], RecordingStudio.allowed_parent_types_for("RecordingStudioBilling::BillingAdmin")
  end

  test "dummy seeds create one of each foundation record idempotently" do
    Current.actor = nil

    load Rails.root.join("db/seeds.rb").to_s

    workspace = Workspace.find_by!(name: "Studio Workspace")
    admin_root = AdminRoot.find_by!(name: "Billing Administration")
    account = RecordingStudioBilling::Account.find_by!(name: "Studio Account")
    billing_admin = RecordingStudioBilling::BillingAdmin.find_by!(key: "billing")
    workspace_recording = RecordingStudio::Recording.find_by!(recordable: workspace)
    admin_root_recording = RecordingStudio::Recording.find_by!(recordable: admin_root)
    account_recording = RecordingStudio::Recording.find_by!(recordable: account)
    billing_admin_recording = RecordingStudio::Recording.find_by!(recordable: billing_admin)

    assert_nil Current.actor
    assert_nil workspace_recording.parent_recording_id
    assert_nil admin_root_recording.parent_recording_id
    assert_equal workspace_recording, account_recording.parent_recording
    assert_equal admin_root_recording, billing_admin_recording.parent_recording
    assert_equal 1, Workspace.count
    assert_equal 1, AdminRoot.count
    assert_equal 1, RecordingStudioBilling::Account.count
    assert_equal 1, RecordingStudioBilling::BillingAdmin.count

    assert_no_difference -> { RecordingStudio::Recording.count } do
      assert_no_difference -> { Workspace.count } do
        assert_no_difference -> { AdminRoot.count } do
          assert_no_difference -> { RecordingStudioBilling::Account.count } do
            assert_no_difference -> { RecordingStudioBilling::BillingAdmin.count } do
              load Rails.root.join("db/seeds.rb").to_s
            end
          end
        end
      end
    end
    assert_nil Current.actor
  ensure
    Current.actor = nil
  end
end
