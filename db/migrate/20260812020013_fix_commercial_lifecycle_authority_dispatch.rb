# frozen_string_literal: true

class FixCommercialLifecycleAuthorityDispatch < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION rs_billing_validate_commercial_lifecycle_authority() RETURNS trigger AS $$
      BEGIN
        IF TG_TABLE_NAME = 'recording_studio_billing_subscription_items' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_subscriptions subscription
            WHERE subscription.id = NEW.subscription_id AND subscription.root_recording_id = NEW.root_recording_id
              AND subscription.account_recording_id = NEW.account_recording_id
          ) THEN RAISE EXCEPTION 'subscription item authority is invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'recording_studio_billing_subscription_item_versions' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_subscription_items item
            WHERE item.id = NEW.subscription_item_id AND item.subscription_id = NEW.subscription_id
              AND item.root_recording_id = NEW.root_recording_id AND item.account_recording_id = NEW.account_recording_id
              AND item.line_key = NEW.line_key
          ) THEN RAISE EXCEPTION 'subscription item version authority is invalid'; END IF;
        ELSIF TG_TABLE_NAME = 'recording_studio_billing_subscription_change_intents' THEN
          IF NOT EXISTS (
            SELECT 1 FROM recording_studio_billing_subscriptions subscription
            WHERE subscription.id = NEW.subscription_id AND subscription.root_recording_id = NEW.root_recording_id
              AND subscription.account_recording_id = NEW.account_recording_id
          ) THEN RAISE EXCEPTION 'subscription change authority is invalid'; END IF;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
