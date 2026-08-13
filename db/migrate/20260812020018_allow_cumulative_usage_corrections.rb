# frozen_string_literal: true

class AllowCumulativeUsageCorrections < ActiveRecord::Migration[8.1]
  def change
    remove_index :recording_studio_billing_usage_corrections, name: "idx_rs_billing_usage_correction_kind"
    add_index :recording_studio_billing_usage_corrections, %i[usage_allocation_id correction_kind],
              name: "idx_rs_billing_usage_correction_kind"
  end
end
