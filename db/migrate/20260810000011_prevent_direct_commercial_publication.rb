# frozen_string_literal: true

class PreventDirectCommercialPublication < ActiveRecord::Migration[8.1]
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
  AUTHORIZATION_FUNCTION = "rs_billing_validate_commercial_publication"
  FEATURE_OVERRIDE_TYPE = "RecordingStudioBilling::FeatureOverride"

  def up
    replace_history_function(insert_guard: true)
    replace_history_triggers(insert_guard: true)
    create_authorization_proof
  end

  def down
    drop_authorization_proof
    replace_history_function(insert_guard: false)
    replace_history_triggers(insert_guard: false)
  end

  private

  def replace_history_function(insert_guard:)
    insert_sql = if insert_guard
                   <<~SQL
                     IF TG_OP = 'INSERT' THEN
                       IF TG_ARGV[0] = '#{FEATURE_OVERRIDE_TYPE}' THEN
                         IF NEW.state <> 'draft' AND
                            current_setting('recording_studio_billing.authorized_feature_override', true) IS DISTINCT FROM 'on' THEN
                           RAISE EXCEPTION 'feature override revision requires an authorized transaction';
                         END IF;
                       ELSIF NEW.state <> 'draft' AND
                             current_setting('recording_studio_billing.authorized_publication', true) IS DISTINCT FROM 'on' THEN
                         RAISE EXCEPTION 'commercial publication requires an authorized transaction';
                       END IF;
                       RETURN NEW;
                     END IF;
                   SQL
                 else
                   ""
                 end

    execute <<~SQL
      CREATE OR REPLACE FUNCTION #{HISTORY_FUNCTION}() RETURNS trigger AS $$
      BEGIN
        #{insert_sql}
        IF OLD.state IN ('published', 'retired') OR NOT EXISTS (
          SELECT 1
          FROM recording_studio_recordings
          WHERE recordable_type = TG_ARGV[0]
            AND recordable_id = OLD.id
        ) THEN
          RAISE EXCEPTION 'published, retired, and historical commercial records are immutable';
        END IF;
        IF TG_OP = 'UPDATE' AND OLD.state = 'draft' AND NEW.state <> 'draft' THEN
          RAISE EXCEPTION 'commercial state changes must create an authorized revision';
        END IF;
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def replace_history_triggers(insert_guard:)
    COMMERCIAL_RECORDABLES.each do |table, recordable_type|
      events = insert_guard ? "INSERT OR UPDATE OR DELETE" : "UPDATE OR DELETE"
      execute "DROP TRIGGER IF EXISTS #{table}_protect_history ON #{table}"
      execute <<~SQL
        CREATE TRIGGER #{table}_protect_history
        BEFORE #{events} ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{HISTORY_FUNCTION}(#{connection.quote(recordable_type)});
      SQL
    end
  end

  def create_authorization_proof
    execute <<~SQL
      CREATE FUNCTION #{AUTHORIZATION_FUNCTION}() RETURNS trigger AS $$
      BEGIN
        IF TG_ARGV[0] = '#{FEATURE_OVERRIDE_TYPE}' THEN
          IF EXISTS (
            SELECT 1
            FROM recording_studio_recordings AS recording
            INNER JOIN recording_studio_events AS creation
              ON creation.recording_id = recording.id
             AND creation.action = 'created'
             AND creation.recordable_type = TG_ARGV[0]
             AND creation.recordable_id = NEW.id
            WHERE recording.recordable_type = TG_ARGV[0]
              AND recording.recordable_id = NEW.id
          ) OR (
            current_setting('recording_studio_billing.authorized_feature_override', true) = 'on' AND EXISTS (
            SELECT 1
            FROM recording_studio_recordings AS recording
            INNER JOIN recording_studio_events AS revision
              ON revision.recording_id = recording.id
             AND revision.action = 'updated'
             AND revision.recordable_type = TG_ARGV[0]
             AND revision.recordable_id = NEW.id
             AND revision.actor_type IS NOT NULL
             AND revision.actor_id IS NOT NULL
            WHERE recording.recordable_type = TG_ARGV[0]
              AND recording.recordable_id = NEW.id
            )
          ) THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'feature override revision is missing its actor-attributed event';
        END IF;
        IF NEW.state = 'draft' THEN
          RETURN NEW;
        END IF;
        IF NOT EXISTS (
          SELECT 1
          FROM recording_studio_recordings AS recording
          INNER JOIN recording_studio_events AS revision
            ON revision.recording_id = recording.id
           AND revision.action = 'updated'
           AND revision.recordable_type = TG_ARGV[0]
           AND revision.recordable_id = NEW.id
           AND revision.actor_type IS NOT NULL
           AND revision.actor_id IS NOT NULL
          INNER JOIN recording_studio_billing_commercial_publication_candidates AS candidate
            ON candidate.candidate_digest = revision.metadata ->> 'commercial_candidate_digest'
           AND candidate.root_recording_id = recording.root_recording_id
           AND candidate.activated_at IS NOT NULL
          INNER JOIN recording_studio_events AS publication_event
            ON publication_event.recording_id = recording.id
           AND publication_event.action = 'commercial_published'
           AND publication_event.metadata ->> 'candidate_digest' = candidate.candidate_digest
           AND publication_event.actor_type = revision.actor_type
           AND publication_event.actor_id = revision.actor_id
          WHERE recording.recordable_type = TG_ARGV[0]
            AND recording.recordable_id = NEW.id
        ) THEN
          RAISE EXCEPTION 'commercial publication is missing its authorized transaction artifacts';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    COMMERCIAL_RECORDABLES.each do |table, recordable_type|
      execute <<~SQL
        CREATE CONSTRAINT TRIGGER #{table}_validate_publication
        AFTER INSERT ON #{table}
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION #{AUTHORIZATION_FUNCTION}(#{connection.quote(recordable_type)});
      SQL
    end
  end

  def drop_authorization_proof
    COMMERCIAL_RECORDABLES.each_key do |table|
      execute "DROP TRIGGER IF EXISTS #{table}_validate_publication ON #{table}"
    end
    execute "DROP FUNCTION IF EXISTS #{AUTHORIZATION_FUNCTION}()"
  end
end
