# frozen_string_literal: true

class CreateRecordingStudioAccesses < ActiveRecord::Migration[7.1]
  def change
    create_table :recording_studio_accesses, id: :uuid do |t|
      t.string :actor_type, null: false
      t.uuid :actor_id, null: false
      t.integer :role, null: false, default: 0

      t.datetime :created_at, null: false
    end

    add_index :recording_studio_accesses, %i[actor_type actor_id],
              name: "index_recording_studio_accesses_on_actor"
  end
end
