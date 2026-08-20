# frozen_string_literal: true

class AddRecordingStudioAccessibleLookupIndexes < ActiveRecord::Migration[8.1]
  def up
    add_index :recording_studio_accesses, %i[actor_type actor_id role],
              name: "index_recording_studio_accesses_on_actor_and_role",
              if_not_exists: true

    add_index :recording_studio_recordings, recording_lookup_index_columns,
              name: "index_recording_studio_recordings_on_recordable_parent_trashed",
              if_not_exists: true
  end

  def down
    remove_index :recording_studio_recordings,
                 name: "index_recording_studio_recordings_on_recordable_parent_trashed",
                 if_exists: true

    remove_index :recording_studio_accesses,
                 name: "index_recording_studio_accesses_on_actor_and_role",
                 if_exists: true
  end

  private

  def recording_lookup_index_columns
    columns = %i[recordable_type recordable_id parent_recording_id]
    columns << :trashed_at if column_exists?(:recording_studio_recordings, :trashed_at)
    columns
  end
end
