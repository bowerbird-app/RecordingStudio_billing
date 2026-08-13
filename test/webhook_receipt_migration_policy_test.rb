# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class WebhookReceiptMigrationPolicyTest < ActiveSupport::TestCase
  test "receipt identity is owned by create migrations and transition migrations are inert" do
    effect_migration = File.read(File.expand_path("../db/migrate/20260812020000_create_usage_allocation_lifecycle.rb",
                                                  __dir__))
    issue_migration = File.read(File.expand_path(
                                  "../db/migrate/20260812020002_add_usage_periods_and_provider_identity.rb", __dir__
                                ))
    receipt_transition = File.read(File.expand_path("../db/migrate/20260813000001_scope_provider_webhook_receipts.rb",
                                                    __dir__))
    handler_transition = File.read(File.expand_path(
                                     "../db/migrate/20260813000000_scope_webhook_effect_identity_by_handler_version.rb", __dir__
                                   ))

    assert_includes effect_migration, "t.references :provider_account_recording, null: false"
    assert_includes effect_migration, "t.uuid :inbound_event_id, null: false"
    assert_includes effect_migration, "idx_rs_billing_webhook_effect_receipt_identity"
    assert_includes issue_migration, "idx_rs_billing_unresolved_webhook_receipt"
    refute_match(/add_(reference|column)|change_column_null|add_index|remove_index/, receipt_transition)
    refute_match(/add_(reference|column)|change_column_null|add_index|remove_index/, handler_transition)
  end

  test "clean-install schema scopes effects and unresolved issues by receipt identity" do
    connection = ActiveRecord::Base.connection

    effect_columns = connection.columns(:recording_studio_billing_webhook_effects).index_by(&:name)
    %w[provider_account_recording_id environment inbound_event_id handler_name action_version].each do |column|
      refute effect_columns.fetch(column).null, "#{column} must be required for webhook effect identity"
    end
    effect_index = connection.indexes(:recording_studio_billing_webhook_effects)
                             .find { |index| index.name == "idx_rs_billing_webhook_effect_receipt_identity" }
    assert effect_index.unique
    assert_equal %w[inbound_event_id provider_account_recording_id environment handler_name action_version],
                 effect_index.columns
    refute(connection.indexes(:recording_studio_billing_webhook_effects)
                     .any? { |index| index.name == "idx_rs_billing_webhook_effect_identity" })

    issue_columns = connection.columns(:recording_studio_billing_reconciliation_issues).index_by(&:name)
    %w[provider_account_recording_id environment inbound_event_id handler_name action_version].each do |column|
      assert issue_columns.key?(column), "#{column} must scope unresolved webhook reconciliation issues"
    end
    issue_index = connection.indexes(:recording_studio_billing_reconciliation_issues)
                            .find { |index| index.name == "idx_rs_billing_unresolved_webhook_receipt" }
    assert issue_index.unique
    assert_equal "(financial_command_id IS NULL)", issue_index.where
    assert_equal %w[provider_account_recording_id environment inbound_event_id handler_name action_version kind],
                 issue_index.columns
    refute(connection.indexes(:recording_studio_billing_reconciliation_issues)
                     .any? { |index| index.name == "idx_rs_billing_unresolved_webhook_identity" })
  end
end
