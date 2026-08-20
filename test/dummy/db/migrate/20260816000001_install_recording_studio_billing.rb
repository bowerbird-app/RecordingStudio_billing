# frozen_string_literal: true

class InstallRecordingStudioBilling < ActiveRecord::Migration[8.1]
  def up
    execute install_sql
  end

  def down
    execute <<~SQL.squish
      DO $$
      DECLARE
        statement text;
      BEGIN
        FOR statement IN
          SELECT format('DROP TABLE IF EXISTS %I CASCADE', tablename)
          FROM pg_tables
          WHERE schemaname = 'public' AND tablename LIKE 'recording_studio_billing_%'
        LOOP
          EXECUTE statement;
        END LOOP;

        FOR statement IN
          SELECT format('DROP FUNCTION IF EXISTS %s CASCADE', oid::regprocedure)
          FROM pg_proc
          WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'rs_billing_%'
        LOOP
          EXECUTE statement;
        END LOOP;
      END
      $$;
    SQL
  end

  private

  def install_sql
    File.read(RecordingStudioBilling::Engine.root.join("db/schema/install_recording_studio_billing.sql"))
  end
end
