# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class RecordingStudioV3Test < ActiveSupport::TestCase
  test "billing roots and capability-owned children validate" do
    assert RecordingStudio.validate_recordable_declarations!
    assert_equal %w[AdminRoot Workspace], RecordingStudio.root_recordable_types.sort
    assert_equal ["Workspace"], RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::Account)
    assert_equal ["AdminRoot"], RecordingStudio.allowed_parent_types_for(RecordingStudioBilling::BillingAdmin)
    assert RecordingStudio.capability_enabled?(:billing, for: Workspace)
    assert RecordingStudio.capability_enabled?(:billing_admin, for: AdminRoot)
  end

  test "workspace records a billing account as a child" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Workspace")))
    account = RecordingStudioBilling::Account.new(name: unique_name("Account"))

    recording = record_child(account, root_recording)

    assert_equal root_recording, recording.parent_recording
    assert_equal root_recording, recording.root_recording
  end

  test "admin root records billing administration as a child" do
    root_recording = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Administration")))
    billing_admin = RecordingStudioBilling::BillingAdmin.new(key: unique_name("billing"))

    recording = record_child(billing_admin, root_recording)

    assert_equal root_recording, recording.parent_recording
    assert_equal root_recording, recording.root_recording
  end

  test "billing children cannot be recorded under the wrong root type" do
    admin_root = RecordingStudio.root_recording_for(AdminRoot.create!(name: unique_name("Administration")))
    account = RecordingStudioBilling::Account.new(name: unique_name("Account"))

    error = assert_raises(RecordingStudio::InvalidParent) { record_child(account, admin_root) }

    assert_equal "RecordingStudioBilling::Account cannot be recorded under AdminRoot", error.message
  end

  private

  def record_child(recordable, root_recording)
    RecordingStudio.record!(
      action: "created",
      recordable: recordable,
      root_recording: root_recording,
      parent_recording: root_recording
    ).recording
  end

  def unique_name(prefix)
    "#{prefix} #{SecureRandom.hex(4)}"
  end
end
