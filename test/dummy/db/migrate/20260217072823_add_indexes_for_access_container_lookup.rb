# frozen_string_literal: true

class AddIndexesForAccessContainerLookup < ActiveRecord::Migration[7.1]
  ROOT_ACCESS_WHERE = <<~SQL.squish.freeze
    recordable_type = 'RecordingStudio::Access'
    AND parent_recording_id IS NULL
    AND trashed_at IS NULL
  SQL

  def up
    # Helps reverse lookup from accesses -> recordings -> containers,
    # especially when filtering by a minimum role.
    add_index :recording_studio_accesses, %i[actor_type actor_id role],
              name: "index_recording_studio_accesses_on_actor_and_role",
              if_not_exists: true

    # Speeds filtering on access recordings scoped to container-level grants.
    add_index :recording_studio_recordings, %i[recordable_type recordable_id parent_recording_id trashed_at],
              name: "index_recording_studio_recordings_on_recordable_parent_trashed",
              if_not_exists: true

    # Best-case index for the exact query shape (root + active + access recordable).
    return unless supports_partial_indexes?

    add_index :recording_studio_recordings, %i[recordable_id container_type container_id],
              name: "idx_rs_recordings_root_access_container",
              where: ROOT_ACCESS_WHERE,
              if_not_exists: true
  end

  def down
    remove_index :recording_studio_recordings,
                 name: "idx_rs_recordings_root_access_container",
                 if_exists: true

    remove_index :recording_studio_recordings,
                 name: "index_recording_studio_recordings_on_recordable_parent_trashed",
                 if_exists: true

    remove_index :recording_studio_accesses,
                 name: "index_recording_studio_accesses_on_actor_and_role",
                 if_exists: true
  end

  private

  def supports_partial_indexes?
    adapter = connection.adapter_name.to_s.downcase
    adapter.include?("postgres") || adapter.include?("sqlite")
  end
end
