# frozen_string_literal: true

class ClassifyLateUsageAndProtectCorrections < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_studio_billing_usage_events, :classification, :string, null: false, default: "timely"
    add_reference :recording_studio_billing_usage_events, :late_usage_period, type: :uuid,
                                                                              foreign_key: { to_table: :recording_studio_billing_usage_periods }
    add_check_constraint :recording_studio_billing_usage_events,
                         "classification IN ('timely', 'late')", name: "rs_billing_usage_event_classification"
    add_check_constraint :recording_studio_billing_usage_events,
                         "(classification = 'timely' AND late_usage_period_id IS NULL) OR (classification = 'late' AND late_usage_period_id IS NOT NULL)",
                         name: "rs_billing_usage_event_late_period"
    execute <<~SQL
      CREATE FUNCTION rs_billing_protect_usage_correction() RETURNS trigger AS $$
      BEGIN
        IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'usage corrections are append-only'; END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      CREATE TRIGGER rs_billing_usage_correction_history
      BEFORE INSERT OR UPDATE OR DELETE ON recording_studio_billing_usage_corrections
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_usage_correction();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
