# frozen_string_literal: true

class RenameRecordingStudioDiscardedAtToTrashedAt < ActiveRecord::Migration[7.1]
  def change
    return unless column_exists?(:recording_studio_recordings, :discarded_at)

    rename_column :recording_studio_recordings, :discarded_at, :trashed_at
  end
end
