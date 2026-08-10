# frozen_string_literal: true

class AddUniqueActiveAccessBoundaryPerParent < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_rs_unique_active_access_boundary_per_parent"

  def up
    return unless supports_partial_indexes?

    add_index :recording_studio_recordings,
              :parent_recording_id,
              unique: true,
              name: INDEX_NAME,
              where: "recordable_type = 'RecordingStudio::AccessBoundary' AND trashed_at IS NULL",
              if_not_exists: true
  end

  def down
    remove_index :recording_studio_recordings, name: INDEX_NAME, if_exists: true
  end

  private

  def supports_partial_indexes?
    adapter = connection.adapter_name.to_s.downcase
    adapter.include?("postgres") || adapter.include?("sqlite")
  end
end
