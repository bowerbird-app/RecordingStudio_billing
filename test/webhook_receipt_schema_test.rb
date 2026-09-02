# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"

class WebhookReceiptSchemaTest < ActiveSupport::TestCase
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

  test "install schema is a single clean-install migration" do
    migrations = Dir.glob(File.expand_path("../db/migrate/*.rb", __dir__)).map { |path| File.basename(path) }

    assert_equal [
      "20260816000001_install_recording_studio_billing.rb",
      "20260820000001_add_default_entitlement_bootstrap.rb",
      "20260822000001_add_name_to_products_and_billing_options.rb",
      "20260901000001_add_unique_invoice_financial_command.rb"
    ], migrations
    schema = File.read(File.expand_path("../db/schema/install_recording_studio_billing.sql", __dir__))
    assert_includes schema, "recording_studio_billing_default_entitlement_bootstraps"
    assert_includes schema, "idx_rs_billing_invoice_command"
    assert_match(/CREATE TABLE public\.recording_studio_billing_products[\s\S]*name character varying NOT NULL/, schema)
    assert_match(/CREATE TABLE public\.recording_studio_billing_billing_options[\s\S]*name character varying NOT NULL/, schema)
    assert_includes schema, "RecordingStudioBilling::DefaultEntitlementBootstrap"
    assert_includes schema, "idx_rs_billing_webhook_effect_receipt_identity"
    assert_includes schema, "idx_rs_billing_unresolved_webhook_receipt"
    assert_includes schema, "fk_rs_billing_manifests_root"
    refute_match(/scope = 'default'|collection_method.*'invoice'|tax_policy.*'automatic'/, schema)
    assert_includes schema, "requires_restart"
    assert_includes schema, "('rejected'"
  end
end
