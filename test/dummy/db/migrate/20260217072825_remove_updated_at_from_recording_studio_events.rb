# frozen_string_literal: true

class RemoveUpdatedAtFromRecordingStudioEvents < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:recording_studio_events)
    return unless column_exists?(:recording_studio_events, :updated_at)

    remove_column :recording_studio_events, :updated_at, :datetime
  end

  def down
    return unless table_exists?(:recording_studio_events)
    return if column_exists?(:recording_studio_events, :updated_at)

    add_column :recording_studio_events,
               :updated_at,
               :datetime,
               null: false,
               default: -> { "CURRENT_TIMESTAMP" }
    change_column_default :recording_studio_events, :updated_at, nil
  end
end
