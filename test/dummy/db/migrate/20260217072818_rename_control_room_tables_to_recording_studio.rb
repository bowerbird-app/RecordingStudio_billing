# frozen_string_literal: true

class RenameControlRoomTablesToRecordingStudio < ActiveRecord::Migration[7.1]
  def up
    if table_exists?(:control_room_recordings) && !table_exists?(:recording_studio_recordings)
      rename_table :control_room_recordings, :recording_studio_recordings
    end

    if table_exists?(:control_room_events) && !table_exists?(:recording_studio_events)
      rename_table :control_room_events, :recording_studio_events
    end

    if table_exists?(:recording_studio_recordings)
      rename_index_if_needed(
        :recording_studio_recordings,
        "index_control_room_recordings_on_container",
        "index_recording_studio_recordings_on_container"
      )
      rename_index_if_needed(
        :recording_studio_recordings,
        "index_control_room_recordings_on_recordable",
        "index_recording_studio_recordings_on_recordable"
      )
      rename_index_if_needed(
        :recording_studio_recordings,
        "index_control_room_recordings_on_parent_recording_id",
        "index_recording_studio_recordings_on_parent_recording_id"
      )

      if foreign_key_exists?(:recording_studio_recordings, :control_room_recordings, column: :parent_recording_id)
        remove_foreign_key :recording_studio_recordings, column: :parent_recording_id
      end
      add_foreign_key :recording_studio_recordings, :recording_studio_recordings, column: :parent_recording_id unless
        foreign_key_exists?(:recording_studio_recordings, :recording_studio_recordings, column: :parent_recording_id)
    end

    return unless table_exists?(:recording_studio_events)

    rename_index_if_needed(
      :recording_studio_events,
      "index_control_room_events_on_recording_id",
      "index_recording_studio_events_on_recording_id"
    )
    rename_index_if_needed(
      :recording_studio_events,
      "index_control_room_events_on_recording_and_idempotency_key",
      "index_recording_studio_events_on_recording_and_idempotency_key"
    )

    if foreign_key_exists?(:recording_studio_events, :control_room_recordings, column: :recording_id)
      remove_foreign_key :recording_studio_events, column: :recording_id
    end
    add_foreign_key :recording_studio_events, :recording_studio_recordings, column: :recording_id unless
      foreign_key_exists?(:recording_studio_events, :recording_studio_recordings, column: :recording_id)
  end

  def down
    if table_exists?(:recording_studio_events) && !table_exists?(:control_room_events)
      if foreign_key_exists?(:recording_studio_events, :recording_studio_recordings, column: :recording_id)
        remove_foreign_key :recording_studio_events, column: :recording_id
      end
      rename_table :recording_studio_events, :control_room_events
    end

    if table_exists?(:recording_studio_recordings) && !table_exists?(:control_room_recordings)
      if foreign_key_exists?(:recording_studio_recordings, :recording_studio_recordings, column: :parent_recording_id)
        remove_foreign_key :recording_studio_recordings, column: :parent_recording_id
      end
      rename_table :recording_studio_recordings, :control_room_recordings
    end

    if table_exists?(:control_room_recordings)
      rename_index_if_needed(
        :control_room_recordings,
        "index_recording_studio_recordings_on_container",
        "index_control_room_recordings_on_container"
      )
      rename_index_if_needed(
        :control_room_recordings,
        "index_recording_studio_recordings_on_recordable",
        "index_control_room_recordings_on_recordable"
      )
      rename_index_if_needed(
        :control_room_recordings,
        "index_recording_studio_recordings_on_parent_recording_id",
        "index_control_room_recordings_on_parent_recording_id"
      )

      add_foreign_key :control_room_recordings, :control_room_recordings, column: :parent_recording_id unless
        foreign_key_exists?(:control_room_recordings, :control_room_recordings, column: :parent_recording_id)
    end

    return unless table_exists?(:control_room_events)

    rename_index_if_needed(
      :control_room_events,
      "index_recording_studio_events_on_recording_id",
      "index_control_room_events_on_recording_id"
    )
    rename_index_if_needed(
      :control_room_events,
      "index_recording_studio_events_on_recording_and_idempotency_key",
      "index_control_room_events_on_recording_and_idempotency_key"
    )

    add_foreign_key :control_room_events, :control_room_recordings, column: :recording_id unless
      foreign_key_exists?(:control_room_events, :control_room_recordings, column: :recording_id)
  end

  private

  def rename_index_if_needed(table, old_name, new_name)
    return unless index_name_exists?(table, old_name)
    return if index_name_exists?(table, new_name)

    rename_index table, old_name, new_name
  end
end
