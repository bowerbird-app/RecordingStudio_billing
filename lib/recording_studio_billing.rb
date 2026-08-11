# frozen_string_literal: true

require "recording_studio_billing/version"
require "recording_studio_billing/hooks"
require "recording_studio_billing/configuration"
require "recording_studio_billing/billable"
require "recording_studio_billing/billing_admin_support"
require "recording_studio_billing/engine"

module RecordingStudioBilling
  RECORDABLE_TYPES = %w[
    RecordingStudioBilling::Account
    RecordingStudioBilling::BillingAdmin
    RecordingStudioBilling::ProviderAccount
    RecordingStudioBilling::Market
    RecordingStudioBilling::Product
    RecordingStudioBilling::BillingOption
    RecordingStudioBilling::Price
    RecordingStudioBilling::OveragePrice
    RecordingStudioBilling::Feature
    RecordingStudioBilling::FeatureOverride
    RecordingStudioBilling::ProductRule
    RecordingStudioBilling::PlanUpdate
    RecordingStudioBilling::UsageUnit
    RecordingStudioBilling::Meter
    RecordingStudioBilling::RateCard
    RecordingStudioBilling::Rate
    RecordingStudioBilling::CostCard
    RecordingStudioBilling::CostRate
  ].freeze

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
    end

    def ensure_account(...)
      EnsureAccount.call(...)
    end

    def ensure_billing_admin(...)
      EnsureBillingAdmin.call(...)
    end

    def create_financial_command(...)
      CreateFinancialCommand.call(...)
    end

    def execute_financial_command(...)
      FinancialCommandExecutor.call(...)
    end

    def expire_financial_command_claims(...)
      ExpireFinancialCommandClaims.call(...)
    end

    def recover_financial_command(...)
      RecoverFinancialCommand.call(...)
    end

    def commercial_publication_in_progress?
      ActiveRecord::Base.connection.select_value(
        "SELECT current_setting('recording_studio_billing.authorized_publication', true) = 'on'"
      ) == true
    end

    def feature_override_revision_in_progress?
      ActiveRecord::Base.connection.select_value(
        "SELECT current_setting('recording_studio_billing.authorized_feature_override', true) = 'on'"
      ) == true
    end

    # rubocop:disable Metrics/MethodLength
    def register_capabilities!
      return unless defined?(RecordingStudio)

      RecordingStudio.register_capability(
        :billing,
        source: "recording_studio_billing",
        child_recordables: "RecordingStudioBilling::Account"
      )
      RecordingStudio.register_capability(
        :billing_admin,
        source: "recording_studio_billing",
        child_recordables: "RecordingStudioBilling::BillingAdmin"
      )
    end
    # rubocop:enable Metrics/MethodLength
  end
end
