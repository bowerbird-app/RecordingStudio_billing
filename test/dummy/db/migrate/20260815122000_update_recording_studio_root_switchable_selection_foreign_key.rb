# frozen_string_literal: true

class UpdateRecordingStudioRootSwitchableSelectionForeignKey < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:recording_studio_root_switchable_selections)

    if foreign_key_exists?(:recording_studio_root_switchable_selections, :recording_studio_recordings)
      remove_foreign_key :recording_studio_root_switchable_selections, :recording_studio_recordings
    end

    add_foreign_key :recording_studio_root_switchable_selections,
                    :recording_studio_recordings,
                    column: :root_recording_id,
                    on_delete: :cascade
  end

  def down
    return unless table_exists?(:recording_studio_root_switchable_selections)
    return unless foreign_key_exists?(:recording_studio_root_switchable_selections, :recording_studio_recordings)

    remove_foreign_key :recording_studio_root_switchable_selections, :recording_studio_recordings
    add_foreign_key :recording_studio_root_switchable_selections,
                    :recording_studio_recordings,
                    column: :root_recording_id
  end
end
