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
    COMMERCIAL_PUBLICATION_CONTEXT_KEY = :recording_studio_billing_commercial_publication

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

    # State changes to catalogue records are only valid while an authorized
    # CommercialPublisher activation is in progress. Isolated execution state
    # keeps that internal capability local to the request/job performing it.
    def with_commercial_publication
      previous = ActiveSupport::IsolatedExecutionState[COMMERCIAL_PUBLICATION_CONTEXT_KEY]
      ActiveSupport::IsolatedExecutionState[COMMERCIAL_PUBLICATION_CONTEXT_KEY] = true
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[COMMERCIAL_PUBLICATION_CONTEXT_KEY] = previous
    end

    def commercial_publication_in_progress?
      ActiveSupport::IsolatedExecutionState[COMMERCIAL_PUBLICATION_CONTEXT_KEY] == true
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
