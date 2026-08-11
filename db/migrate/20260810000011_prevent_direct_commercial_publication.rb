# frozen_string_literal: true

class PreventDirectCommercialPublication < ActiveRecord::Migration[8.1]
  HISTORY_FUNCTION = "rs_billing_protect_commercial_history"

  def up
    replace_history_function
  end

  def down
    replace_history_function(prevent_direct_publication: false)
  end

  private

  def replace_history_function(prevent_direct_publication: true)
    direct_publication_guard = if prevent_direct_publication
                                 <<~SQL
                                   IF TG_OP = 'UPDATE' AND OLD.state = 'draft' AND NEW.state <> 'draft' THEN
                                     RAISE EXCEPTION 'commercial publication must create an authorized revision';
                                   END IF;
                                 SQL
                               else
                                 ""
                               end

    execute <<~SQL
      CREATE OR REPLACE FUNCTION #{HISTORY_FUNCTION}() RETURNS trigger AS $$
      BEGIN
        IF OLD.state IN ('published', 'retired') OR NOT EXISTS (
          SELECT 1
          FROM recording_studio_recordings
          WHERE recordable_type = TG_ARGV[0]
            AND recordable_id = OLD.id
        ) THEN
          RAISE EXCEPTION 'published, retired, and historical commercial records are immutable';
        END IF;
        #{direct_publication_guard}
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end
end
