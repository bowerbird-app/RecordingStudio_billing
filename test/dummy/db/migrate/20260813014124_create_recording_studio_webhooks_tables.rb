# frozen_string_literal: true

class CreateRecordingStudioWebhooksTables < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_webhooks_endpoints, id: :uuid do |t|
      t.references :recording_studio_recording,
        type: :uuid,
        null: false,
        foreign_key: { to_table: :recording_studio_recordings },
        index: false
      t.string :provider_name, null: false
      t.string :label, null: false
      t.jsonb :identity, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.jsonb :policy_overrides, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_webhooks_endpoints,
      %i[provider_name recording_studio_recording_id],
      name: "index_rsw_endpoints_on_provider_and_recording"
    add_index :recording_studio_webhooks_endpoints, :provider_name
    add_index :recording_studio_webhooks_endpoints,
      :recording_studio_recording_id,
      name: "index_rsw_endpoints_on_recording_id"

    create_table :recording_studio_webhooks_endpoint_tokens, id: :uuid do |t|
      t.references :endpoint,
        type: :uuid,
        null: false,
        foreign_key: { to_table: :recording_studio_webhooks_endpoints },
        index: false
      t.string :token
      t.string :digest, null: false
      t.string :prefix, null: false
      t.datetime :active_at, null: false
      t.datetime :expires_at
      t.datetime :revoked_at
      t.string :revoked_by_actor_id
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :recording_studio_webhooks_endpoint_tokens, :digest
    add_index :recording_studio_webhooks_endpoint_tokens,
      %i[endpoint_id active_at],
      name: "index_rsw_tokens_on_endpoint_and_active_at"

    create_table :recording_studio_webhooks_inbound_events, id: :uuid do |t|
      t.references :endpoint,
        type: :uuid,
        null: false,
        foreign_key: { to_table: :recording_studio_webhooks_endpoints },
        index: false
      t.references :endpoint_token,
        type: :uuid,
        null: false,
        foreign_key: { to_table: :recording_studio_webhooks_endpoint_tokens },
        index: false
      t.string :provider_name, null: false
      t.string :event_type, null: false
      t.string :provider_event_id
      t.string :payload_digest, null: false
      t.string :deduplication_key, null: false
      t.jsonb :payload, null: false, default: {}
      t.jsonb :provenance, null: false, default: {}
      t.jsonb :endpoint_snapshot, null: false, default: {}
      t.jsonb :token_snapshot, null: false, default: {}
      t.jsonb :policy_snapshot, null: false, default: {}
      t.string :status, null: false, default: "accepted"
      t.datetime :received_at, null: false
      t.timestamps
    end
    add_index :recording_studio_webhooks_inbound_events,
      %i[endpoint_id deduplication_key],
      unique: true,
      name: "index_rsw_events_on_endpoint_and_deduplication"
    add_index :recording_studio_webhooks_inbound_events,
      %i[provider_name event_type received_at],
      name: "index_rsw_events_on_provider_event_received"
    add_index :recording_studio_webhooks_inbound_events,
      :endpoint_token_id,
      name: "index_rsw_events_on_endpoint_token_id"

    create_table :recording_studio_webhooks_action_attempts, id: :uuid do |t|
      t.references :inbound_event,
        type: :uuid,
        null: false,
        foreign_key: { to_table: :recording_studio_webhooks_inbound_events },
        index: false
      t.string :action_name, null: false
      t.integer :execution_position, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :queued_at
      t.datetime :started_at
      t.datetime :completed_at
      t.string :last_error
      t.jsonb :endpoint_snapshot, null: false, default: {}
      t.jsonb :token_snapshot, null: false, default: {}
      t.jsonb :policy_snapshot, null: false, default: {}
      t.jsonb :action_snapshot, null: false, default: {}
      t.jsonb :attempt_history, null: false, default: []
      t.timestamps
    end
    add_index :recording_studio_webhooks_action_attempts,
      %i[inbound_event_id action_name],
      unique: true,
      name: "index_rsw_attempts_on_event_and_action"
    add_index :recording_studio_webhooks_action_attempts,
      %i[status next_attempt_at],
      name: "index_rsw_attempts_on_status_and_next_attempt"
    add_index :recording_studio_webhooks_action_attempts,
      %i[inbound_event_id execution_position],
      unique: true,
      name: "index_rsw_attempts_on_event_and_position"
    add_index :recording_studio_webhooks_action_attempts,
      :inbound_event_id,
      name: "index_rsw_attempts_on_event_id"
  end
end
