# frozen_string_literal: true

class ReplaceUsagePolicyKinds < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE recording_studio_billing_usage_allowance_policies DROP CONSTRAINT rs_billing_usage_allowance_policy_quantities"
    execute <<~SQL
      ALTER TABLE recording_studio_billing_usage_allowance_policies
      ADD CONSTRAINT rs_billing_usage_allowance_policy_quantities
      CHECK (policy_kind IN ('hard_limit', 'prepaid_only', 'prepaid_then_block', 'prepaid_then_overage', 'automatic_overage', 'unlimited', 'addon_required')
             AND limit_quantity >= 0 AND consumed_quantity >= 0 AND consumed_quantity <= limit_quantity)
    SQL
  end

  def down
    execute "ALTER TABLE recording_studio_billing_usage_allowance_policies DROP CONSTRAINT rs_billing_usage_allowance_policy_quantities"
    execute <<~SQL
      ALTER TABLE recording_studio_billing_usage_allowance_policies
      ADD CONSTRAINT rs_billing_usage_allowance_policy_quantities
      CHECK (policy_kind IN ('hard_cap', 'soft_cap') AND limit_quantity >= 0 AND consumed_quantity >= 0 AND consumed_quantity <= limit_quantity)
    SQL
  end
end
