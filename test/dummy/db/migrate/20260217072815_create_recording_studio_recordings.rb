# frozen_string_literal: true

class CreateRecordingStudioRecordings < ActiveRecord::Migration[7.1]
  def change
    create_table :recording_studio_recordings, id: :uuid do |t|
      t.string :recordable_type, null: false
      t.uuid :recordable_id, null: false
      t.string :container_type, null: false
      t.uuid :container_id, null: false
      t.datetime :trashed_at

      t.timestamps
    end

    add_index :recording_studio_recordings, %i[container_type container_id],
              name: "index_recording_studio_recordings_on_container"
    add_index :recording_studio_recordings, %i[recordable_type recordable_id],
              name: "index_recording_studio_recordings_on_recordable"
  end
end
