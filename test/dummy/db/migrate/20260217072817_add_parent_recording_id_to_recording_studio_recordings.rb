# frozen_string_literal: true

class AddParentRecordingIdToRecordingStudioRecordings < ActiveRecord::Migration[7.1]
  def change
    add_column :recording_studio_recordings, :parent_recording_id, :uuid
    add_index :recording_studio_recordings, :parent_recording_id
    add_foreign_key :recording_studio_recordings, :recording_studio_recordings, column: :parent_recording_id
  end
end
