# frozen_string_literal: true

class ReplaceContainerWithRootRecording < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_studio_recordings, :root_recording_id, :uuid
    add_index :recording_studio_recordings, :root_recording_id, name: "index_rs_recordings_on_root_recording"
    add_foreign_key :recording_studio_recordings, :recording_studio_recordings, column: :root_recording_id

    remove_index :recording_studio_recordings, name: "idx_rs_recordings_root_access_container", if_exists: true
    add_index :recording_studio_recordings, %i[recordable_id root_recording_id],
              name: "idx_rs_recordings_root_access",
              where: "((recordable_type)::text = 'RecordingStudio::Access'::text) " \
                     "AND (parent_recording_id IS NOT NULL) AND (trashed_at IS NULL)"

    remove_index :recording_studio_recordings, name: "index_recording_studio_recordings_on_container", if_exists: true
    remove_column :recording_studio_recordings, :container_type, :string
    remove_column :recording_studio_recordings, :container_id, :uuid
  end

  def down
    add_column :recording_studio_recordings, :container_type, :string
    add_column :recording_studio_recordings, :container_id, :uuid
    execute <<~SQL.squish
      UPDATE recording_studio_recordings AS recording
      SET container_type = root.recordable_type,
          container_id = root.recordable_id
      FROM recording_studio_recordings AS root
      WHERE root.id = COALESCE(recording.root_recording_id, recording.id)
    SQL
    change_column_null :recording_studio_recordings, :container_type, false
    change_column_null :recording_studio_recordings, :container_id, false
    add_index :recording_studio_recordings, %i[container_type container_id],
              name: "index_recording_studio_recordings_on_container"

    remove_index :recording_studio_recordings, name: "idx_rs_recordings_root_access", if_exists: true
    add_index :recording_studio_recordings, %i[recordable_id container_type container_id],
              name: "idx_rs_recordings_root_access_container",
              where: "((recordable_type)::text = 'RecordingStudio::Access'::text) " \
                     "AND (parent_recording_id IS NULL) AND (trashed_at IS NULL)"

    remove_foreign_key :recording_studio_recordings, column: :root_recording_id
    remove_index :recording_studio_recordings, name: "index_rs_recordings_on_root_recording", if_exists: true
    remove_column :recording_studio_recordings, :root_recording_id, :uuid
  end
end
