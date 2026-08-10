# frozen_string_literal: true

class AddCommercialDeliveryRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :recording_studio_billing_markets, :country_groups, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_markets, :default_currency_code, :string
    add_column :recording_studio_billing_products, :feature_values, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_billing_options, :feature_values, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_prices, :feature_values, :jsonb, null: false, default: {}
    add_column :recording_studio_billing_features, :definition, :jsonb, null: false, default: {}
    add_reference :recording_studio_billing_product_rules, :target_product_recording,
                  type: :uuid, foreign_key: { to_table: :recording_studio_recordings }
    add_column :recording_studio_billing_product_rules, :conditions, :jsonb, null: false, default: {}

    create_table :recording_studio_billing_commercial_manifests, id: :uuid do |t|
      t.uuid :root_recording_id, null: false
      t.string :schema_version, null: false
      t.string :resolver_version, null: false
      t.string :manifest_digest, null: false
      t.jsonb :canonical_data, null: false
      t.jsonb :recording_snapshots, null: false, default: []
      t.jsonb :snapshot_references, null: false, default: {}
      t.datetime :used_at
      t.timestamps
    end
    add_index :recording_studio_billing_commercial_manifests, :manifest_digest, unique: true
    add_index :recording_studio_billing_commercial_manifests, :root_recording_id

    create_table :recording_studio_billing_commercial_publication_candidates, id: :uuid do |t|
      t.uuid :root_recording_id, null: false
      t.string :candidate_digest, null: false
      t.datetime :effective_at, null: false
      t.datetime :activated_at
      t.jsonb :manifest_digests, null: false, default: []
      t.jsonb :recording_snapshots, null: false, default: []
      t.timestamps
    end
    add_index :recording_studio_billing_commercial_publication_candidates, :candidate_digest, unique: true,
              name: "rs_billing_publication_candidates_digest"
    add_index :recording_studio_billing_commercial_publication_candidates, :effective_at
  end
end
