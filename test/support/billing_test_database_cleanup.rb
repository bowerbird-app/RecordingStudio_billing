# frozen_string_literal: true

module BillingTestDatabaseCleanup
  LOCK_NAMESPACE = 8_427_731

  def self.clear!
    connection = ActiveRecord::Base.connection
    connection.transaction do
      connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE})")
      tables = connection.tables.grep(/\Arecording_studio_billing_/) + [
        RecordingStudio::Event.table_name,
        RecordingStudio::Recording.table_name
      ]
      tables << RecordingStudioRootSwitchable::Selection.table_name if defined?(RecordingStudioRootSwitchable::Selection)
      quoted_tables = tables.uniq.map { |table| connection.quote_table_name(table) }.join(", ")

      connection.execute("TRUNCATE TABLE #{quoted_tables} RESTART IDENTITY CASCADE")
      Project.delete_all if defined?(Project)
      Workspace.delete_all
      AdminRoot.delete_all
      User.delete_all if defined?(User)
    end
  end
end
