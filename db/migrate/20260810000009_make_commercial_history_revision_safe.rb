# frozen_string_literal: true

class MakeCommercialHistoryRevisionSafe < ActiveRecord::Migration[8.1]
  PRICES = :recording_studio_billing_prices
  OVERAGE_PRICES = :recording_studio_billing_overage_prices
  BILLING_OPTIONS = :recording_studio_billing_billing_options
  MANIFESTS = :recording_studio_billing_commercial_manifests
  CANDIDATES = :recording_studio_billing_commercial_publication_candidates

  def up
    remove_revision_unsafe_indexes
    harden_quantities
    add_history_foreign_keys
    correct_recordable_history_guard
    protect_delivery_history
  end

  def down
    execute "DROP TRIGGER IF EXISTS rs_billing_manifests_protect_history ON #{MANIFESTS}"
    execute "DROP TRIGGER IF EXISTS rs_billing_candidates_protect_history ON #{CANDIDATES}"
    execute "DROP FUNCTION IF EXISTS rs_billing_protect_manifest_history()"
    execute "DROP FUNCTION IF EXISTS rs_billing_protect_candidate_history()"
    remove_foreign_key MANIFESTS, name: "fk_rs_billing_manifests_root", if_exists: true
    remove_foreign_key CANDIDATES, name: "fk_rs_billing_candidates_root", if_exists: true
    restore_published_indexes
  end

  private

  def remove_revision_unsafe_indexes
    remove_index PRICES, name: "recording_studio_billing_prices_published", if_exists: true
    remove_index OVERAGE_PRICES, name: "recording_studio_billing_overage_prices_published", if_exists: true
  end

  def restore_published_indexes
    add_index PRICES,
              %i[billing_option_recording_id scope market_recording_id currency_code],
              unique: true, where: "state = 'published'",
              name: "recording_studio_billing_prices_published",
              if_not_exists: true
    add_index OVERAGE_PRICES,
              %i[billing_option_recording_id scope market_recording_id usage_unit_recording_id currency_code],
              unique: true, where: "state = 'published'",
              name: "recording_studio_billing_overage_prices_published",
              if_not_exists: true
  end

  def harden_quantities
    change_column_default BILLING_OPTIONS, :default_quantity, from: nil, to: 1
    execute "UPDATE #{BILLING_OPTIONS} SET default_quantity = 1 WHERE default_quantity IS NULL"
    change_column_null BILLING_OPTIONS, :default_quantity, false
    add_quantity_constraint("minimum_quantity >= 0 OR minimum_quantity IS NULL",
                            "rs_billing_options_minimum_quantity")
    add_quantity_constraint("maximum_quantity > 0 OR maximum_quantity IS NULL",
                            "rs_billing_options_maximum_quantity")
    add_quantity_constraint("default_quantity > 0", "rs_billing_options_default_quantity")
    add_quantity_constraint(
      "minimum_quantity IS NULL OR maximum_quantity IS NULL OR minimum_quantity <= maximum_quantity",
      "rs_billing_options_quantity_bounds"
    )
    add_quantity_constraint(
      "minimum_quantity IS NULL OR default_quantity >= minimum_quantity",
      "rs_billing_options_default_minimum"
    )
    add_quantity_constraint(
      "maximum_quantity IS NULL OR default_quantity <= maximum_quantity",
      "rs_billing_options_default_maximum"
    )
  end

  def add_quantity_constraint(expression, name)
    return if check_constraint_exists?(BILLING_OPTIONS, name:)

    add_check_constraint BILLING_OPTIONS, expression, name:
  end

  def add_history_foreign_keys
    unless foreign_key_exists?(MANIFESTS, :recording_studio_recordings, name: "fk_rs_billing_manifests_root")
      add_foreign_key MANIFESTS, :recording_studio_recordings,
                      column: :root_recording_id, name: "fk_rs_billing_manifests_root"
    end
    return if foreign_key_exists?(CANDIDATES, :recording_studio_recordings, name: "fk_rs_billing_candidates_root")

    add_foreign_key CANDIDATES, :recording_studio_recordings,
                    column: :root_recording_id, name: "fk_rs_billing_candidates_root"
  end

  def correct_recordable_history_guard
    execute <<~SQL
      CREATE OR REPLACE FUNCTION rs_billing_protect_commercial_history() RETURNS trigger AS $$
      BEGIN
        IF OLD.state IN ('published', 'retired') THEN
          RAISE EXCEPTION 'published and retired commercial records are immutable';
        END IF;
        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
  end

  def protect_delivery_history
    execute <<~SQL
      CREATE OR REPLACE FUNCTION rs_billing_protect_manifest_history() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'commercial manifests are immutable';
        END IF;
        IF OLD.used_at IS NULL AND NEW.used_at IS NOT NULL AND
           (to_jsonb(OLD) - 'used_at' - 'updated_at') =
             (to_jsonb(NEW) - 'used_at' - 'updated_at') THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'commercial manifests are immutable';
      END;
      $$ LANGUAGE plpgsql;

      CREATE OR REPLACE FUNCTION rs_billing_protect_candidate_history() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'commercial publication candidates are immutable';
        END IF;
        IF OLD.activated_at IS NULL AND NEW.activated_at IS NOT NULL AND
           (to_jsonb(OLD) - 'activated_at' - 'updated_at') =
             (to_jsonb(NEW) - 'activated_at' - 'updated_at') THEN
          RETURN NEW;
        END IF;
        RAISE EXCEPTION 'commercial publication candidates are immutable';
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS rs_billing_manifests_protect_history ON #{MANIFESTS};
      CREATE TRIGGER rs_billing_manifests_protect_history
      BEFORE UPDATE OR DELETE ON #{MANIFESTS}
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_manifest_history();

      DROP TRIGGER IF EXISTS rs_billing_candidates_protect_history ON #{CANDIDATES};
      CREATE TRIGGER rs_billing_candidates_protect_history
      BEFORE UPDATE OR DELETE ON #{CANDIDATES}
      FOR EACH ROW EXECUTE FUNCTION rs_billing_protect_candidate_history();
    SQL
  end
end
