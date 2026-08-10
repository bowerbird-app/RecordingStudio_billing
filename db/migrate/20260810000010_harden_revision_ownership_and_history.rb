# frozen_string_literal: true

class HardenRevisionOwnershipAndHistory < ActiveRecord::Migration[8.1]
  OWNED_RECORDABLES = {
    recording_studio_billing_accounts: {
      type: "RecordingStudioBilling::Account",
      history_index: "idx_rs_billing_account_root_history",
      current_index: "idx_rs_billing_one_account_per_root"
    },
    recording_studio_billing_billing_admins: {
      type: "RecordingStudioBilling::BillingAdmin",
      history_index: "idx_rs_billing_admin_root_history",
      current_index: "idx_rs_billing_one_admin_per_root"
    }
  }.freeze

  COMMERCIAL_RECORDABLES = {
    recording_studio_billing_provider_accounts: "RecordingStudioBilling::ProviderAccount",
    recording_studio_billing_markets: "RecordingStudioBilling::Market",
    recording_studio_billing_products: "RecordingStudioBilling::Product",
    recording_studio_billing_billing_options: "RecordingStudioBilling::BillingOption",
    recording_studio_billing_prices: "RecordingStudioBilling::Price",
    recording_studio_billing_overage_prices: "RecordingStudioBilling::OveragePrice",
    recording_studio_billing_features: "RecordingStudioBilling::Feature",
    recording_studio_billing_feature_overrides: "RecordingStudioBilling::FeatureOverride",
    recording_studio_billing_product_rules: "RecordingStudioBilling::ProductRule",
    recording_studio_billing_plan_updates: "RecordingStudioBilling::PlanUpdate",
    recording_studio_billing_usage_units: "RecordingStudioBilling::UsageUnit",
    recording_studio_billing_meters: "RecordingStudioBilling::Meter",
    recording_studio_billing_rate_cards: "RecordingStudioBilling::RateCard",
    recording_studio_billing_rates: "RecordingStudioBilling::Rate",
    recording_studio_billing_cost_cards: "RecordingStudioBilling::CostCard",
    recording_studio_billing_cost_rates: "RecordingStudioBilling::CostRate"
  }.freeze

  HISTORY_FUNCTION = "rs_billing_protect_commercial_history"

  def up
    move_current_ownership_constraints
    backfill_historical_root_ownership
    protect_historical_drafts
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Revision-safe ownership and historical draft protection cannot be removed after snapshots exist."
  end

  private

  def backfill_historical_root_ownership
    OWNED_RECORDABLES.each do |table, specification|
      recordable_type = specification.fetch(:type)
      ensure_snapshot_roots_are_unambiguous!(recordable_type)

      execute <<~SQL.squish
        WITH snapshot_roots AS (
          #{snapshot_roots_sql(recordable_type)}
        ),
        resolved_roots AS (
          SELECT snapshot_id, MIN(root_recording_id::text)::uuid AS root_recording_id
          FROM snapshot_roots
          GROUP BY snapshot_id
          HAVING COUNT(DISTINCT root_recording_id) = 1
        )
        UPDATE #{table} AS snapshot
        SET root_recording_id = resolved_roots.root_recording_id
        FROM resolved_roots
        WHERE snapshot.id = resolved_roots.snapshot_id
          AND snapshot.root_recording_id IS DISTINCT FROM resolved_roots.root_recording_id
      SQL
    end
  end

  def ensure_snapshot_roots_are_unambiguous!(recordable_type)
    conflicts = select_value(<<~SQL.squish).to_i
      WITH snapshot_roots AS (
        #{snapshot_roots_sql(recordable_type)}
      )
      SELECT COUNT(*)
      FROM (
        SELECT snapshot_id
        FROM snapshot_roots
        GROUP BY snapshot_id
        HAVING COUNT(DISTINCT root_recording_id) > 1
      ) AS ambiguous_snapshots
    SQL
    return if conflicts.zero?

    raise ActiveRecord::MigrationError,
          "#{recordable_type} history contains snapshots assigned to multiple Recording Studio roots."
  end

  def snapshot_roots_sql(recordable_type)
    quoted_type = connection.quote(recordable_type)
    <<~SQL.squish
      SELECT recording.recordable_id AS snapshot_id, recording.root_recording_id
      FROM recording_studio_recordings AS recording
      WHERE recording.recordable_type = #{quoted_type}
      UNION
      SELECT event.recordable_id AS snapshot_id, recording.root_recording_id
      FROM recording_studio_events AS event
      INNER JOIN recording_studio_recordings AS recording ON recording.id = event.recording_id
      WHERE event.recordable_type = #{quoted_type}
      UNION
      SELECT event.previous_recordable_id AS snapshot_id, recording.root_recording_id
      FROM recording_studio_events AS event
      INNER JOIN recording_studio_recordings AS recording ON recording.id = event.recording_id
      WHERE event.previous_recordable_type = #{quoted_type}
        AND event.previous_recordable_id IS NOT NULL
    SQL
  end

  def move_current_ownership_constraints
    OWNED_RECORDABLES.each do |table, specification|
      remove_index table, :root_recording_id, if_exists: true
      add_index table, :root_recording_id, name: specification.fetch(:history_index)
      add_index :recording_studio_recordings, :root_recording_id,
                unique: true,
                where: "recordable_type = #{connection.quote(specification.fetch(:type))}",
                name: specification.fetch(:current_index)
    end
  end

  def protect_historical_drafts
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
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    COMMERCIAL_RECORDABLES.each do |table, recordable_type|
      execute "DROP TRIGGER IF EXISTS #{table}_protect_history ON #{table}"
      execute <<~SQL
        CREATE TRIGGER #{table}_protect_history
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{HISTORY_FUNCTION}(#{connection.quote(recordable_type)});
      SQL
    end
  end
end
