# frozen_string_literal: true

# This migration comes from recording_studio (originally 20260218000001)
class CreateRecordingStudioDeviceSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_device_sessions, id: :uuid do |t|
      t.string :actor_type, null: false
      t.uuid :actor_id, null: false
      t.string :device_fingerprint, null: false
      t.string :device_name
      t.datetime :last_active_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.uuid :root_recording_id, null: false
      t.string :user_agent

      t.timestamps
    end

    add_index :recording_studio_device_sessions,
              %i[actor_type actor_id device_fingerprint],
              unique: true,
              name: "index_rs_device_sessions_on_actor_and_fingerprint"
    add_index :recording_studio_device_sessions,
              :root_recording_id,
              name: "index_rs_device_sessions_on_root_recording"
    add_foreign_key :recording_studio_device_sessions,
                    :recording_studio_recordings,
                    column: :root_recording_id
  end
end
