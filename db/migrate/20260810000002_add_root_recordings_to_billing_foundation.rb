# frozen_string_literal: true

class AddRootRecordingsToBillingFoundation < ActiveRecord::Migration[8.1]
  def change
    add_reference :recording_studio_billing_accounts, :root_recording,
                  type: :uuid, null: true, index: false, foreign_key: { to_table: :recording_studio_recordings }
    add_reference :recording_studio_billing_billing_admins, :root_recording,
                  type: :uuid, null: true, index: false, foreign_key: { to_table: :recording_studio_recordings }

    remove_index :recording_studio_billing_accounts, :name
    remove_index :recording_studio_billing_billing_admins, :key

    execute <<~SQL.squish
      UPDATE recording_studio_billing_accounts AS account
      SET root_recording_id = recording.root_recording_id
      FROM recording_studio_recordings AS recording
      WHERE recording.recordable_type = 'RecordingStudioBilling::Account'
        AND recording.recordable_id = account.id
    SQL
    execute <<~SQL.squish
      UPDATE recording_studio_billing_billing_admins AS billing_admin
      SET root_recording_id = recording.root_recording_id
      FROM recording_studio_recordings AS recording
      WHERE recording.recordable_type = 'RecordingStudioBilling::BillingAdmin'
        AND recording.recordable_id = billing_admin.id
    SQL

    change_column_null :recording_studio_billing_accounts, :root_recording_id, false
    change_column_null :recording_studio_billing_billing_admins, :root_recording_id, false
    add_index :recording_studio_billing_accounts, :root_recording_id, unique: true
    add_index :recording_studio_billing_billing_admins, :root_recording_id, unique: true
  end
end
