# frozen_string_literal: true

class CreateRecordingStudioRootSwitchableSelections < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_root_switchable_selections, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :actor_id
      t.string :actor_type
      t.datetime :created_at, null: false
      t.string :device_browser
      t.string :device_key, null: false
      t.string :device_label
      t.string :device_platform
      t.string :device_type
      t.datetime :last_used_at, null: false
      t.uuid :root_recording_id, null: false
      t.string :scope_key, null: false
      t.datetime :updated_at, null: false
      t.text :user_agent

      t.index [ :actor_type, :actor_id, :device_key, :scope_key ], unique: true, name: "idx_rs_root_switchable_actor_device_scope", where: "(actor_id IS NOT NULL)"
      t.index [ :device_key, :scope_key ], unique: true, name: "idx_rs_root_switchable_anonymous_device_scope", where: "(actor_id IS NULL)"
      t.index [ :root_recording_id ], name: "idx_rs_root_switchable_root_recording"
    end
  end
end
