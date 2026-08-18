# frozen_string_literal: true

# Accessible 0.6 stores grant recordables in recording_studio_accesses.
# Core previously dropped this table; recreate it for the Accessible addon.
class RecreateRecordingStudioAccessesForAccessible < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:recording_studio_accesses)

    create_table :recording_studio_accesses, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :actor_type, null: false
      t.uuid :actor_id, null: false
      t.integer :role, null: false, default: 0

      t.datetime :created_at, null: false
    end

    add_index :recording_studio_accesses, %i[actor_type actor_id],
              name: "index_recording_studio_accesses_on_actor"
    add_index :recording_studio_accesses, %i[actor_type actor_id role],
              name: "index_recording_studio_accesses_on_actor_and_role"
  end
end
