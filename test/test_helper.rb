# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require_relative "simplecov_helper"
require "minitest/autorun"
require "rails"
require "recording_studio_billing"

module BillingTestDatabaseCleanup
  def self.clear!
    connection = ActiveRecord::Base.connection
    tables = connection.tables.grep(/\Arecording_studio_billing_/) + [
      RecordingStudio::Event.table_name,
      RecordingStudio::Recording.table_name
    ]
    tables << RecordingStudioRootSwitchable::Selection.table_name if defined?(RecordingStudioRootSwitchable::Selection)
    quoted_tables = tables.uniq.map { |table| connection.quote_table_name(table) }.join(", ")

    connection.execute("TRUNCATE TABLE #{quoted_tables} RESTART IDENTITY CASCADE")
    Workspace.delete_all
    AdminRoot.delete_all
    User.delete_all if defined?(User)
  end
end
