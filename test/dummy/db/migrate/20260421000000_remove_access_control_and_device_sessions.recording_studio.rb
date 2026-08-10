# frozen_string_literal: true

# This migration comes from recording_studio (originally 20260421000000)
class RemoveAccessControlAndDeviceSessions < ActiveRecord::Migration[8.1]
  LEGACY_RECORDABLE_TYPES = %w[RecordingStudio::Access RecordingStudio::AccessBoundary].freeze

  def up
    legacy_recording_ids = select_values(<<~SQL.squish)
      SELECT id FROM recording_studio_recordings
      WHERE recordable_type IN ('RecordingStudio::Access', 'RecordingStudio::AccessBoundary')
    SQL

    if legacy_recording_ids.any?
      quoted_ids = legacy_recording_ids.map { |id| quote(id) }.join(", ")
      unsafe_child_count = select_value(<<~SQL.squish)
        SELECT COUNT(*) FROM recording_studio_recordings
        WHERE parent_recording_id IN (#{quoted_ids})
          AND recordable_type NOT IN ('RecordingStudio::Access', 'RecordingStudio::AccessBoundary')
      SQL
      if unsafe_child_count.to_i.positive?
        raise ActiveRecord::IrreversibleMigration,
              "legacy access boundary recordings still have non-legacy children"
      end

      execute <<~SQL.squish
        DELETE FROM recording_studio_events
        WHERE recording_id IN (#{quoted_ids})
           OR recordable_type IN ('RecordingStudio::Access', 'RecordingStudio::AccessBoundary')
      SQL

      LEGACY_RECORDABLE_TYPES.each do |recordable_type|
        execute <<~SQL.squish
          DELETE FROM recording_studio_recordings
          WHERE recordable_type = #{quote(recordable_type)}
        SQL
      end
    end

    remove_index :recording_studio_recordings, name: "idx_rs_recordings_root_access", if_exists: true
    remove_index :recording_studio_recordings,
                 name: "index_rs_unique_active_access_boundary_per_parent",
                 if_exists: true

    drop_table :recording_studio_device_sessions, if_exists: true
    drop_table :recording_studio_access_boundaries, if_exists: true
    drop_table :recording_studio_accesses, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "access control and device session features were removed from core"
  end
end
