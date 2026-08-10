# frozen_string_literal: true

class RenameServiceAccountActorTypes < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:recording_studio_events)

    execute <<~SQL.squish
      UPDATE recording_studio_events
      SET actor_type = 'SystemActor'
      WHERE actor_type = 'ServiceAccount'
    SQL

    execute <<~SQL.squish
      UPDATE recording_studio_events
      SET impersonator_type = 'SystemActor'
      WHERE impersonator_type = 'ServiceAccount'
    SQL
  end

  def down
    return unless table_exists?(:recording_studio_events)

    execute <<~SQL.squish
      UPDATE recording_studio_events
      SET actor_type = 'ServiceAccount'
      WHERE actor_type = 'SystemActor'
    SQL

    execute <<~SQL.squish
      UPDATE recording_studio_events
      SET impersonator_type = 'ServiceAccount'
      WHERE impersonator_type = 'SystemActor'
    SQL
  end
end
