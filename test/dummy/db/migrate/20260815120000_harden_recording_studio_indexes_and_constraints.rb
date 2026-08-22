# frozen_string_literal: true

class HardenRecordingStudioIndexesAndConstraints < ActiveRecord::Migration[8.1]
  def change
    add_index :recording_studio_recordings,
              %i[recordable_type recordable_id],
              unique: true,
              where: "parent_recording_id IS NULL",
              name: "index_rs_unique_root_recording_per_recordable",
              if_not_exists: true

    add_index :recording_studio_recordings,
              %i[root_recording_id parent_recording_id],
              name: "index_rs_recordings_on_root_and_parent",
              if_not_exists: true

    add_index :recording_studio_recordings,
              %i[root_recording_id recordable_type recordable_id],
              name: "index_rs_recordings_on_root_and_recordable",
              if_not_exists: true

    add_index :recording_studio_events,
              %i[recording_id occurred_at created_at],
              order: { occurred_at: :desc, created_at: :desc },
              name: "index_rs_events_on_recording_and_timeline",
              if_not_exists: true

    add_index :recording_studio_events,
              %i[action occurred_at],
              name: "index_rs_events_on_action_and_occurred_at",
              if_not_exists: true

    add_index :recording_studio_events,
              %i[actor_type actor_id occurred_at],
              name: "index_rs_events_on_actor_and_occurred_at",
              if_not_exists: true
  end
end
