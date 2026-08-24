# frozen_string_literal: true

require "recording_studio_billing/version"
require "uri"
require "recording_studio_billing/hooks"
require "recording_studio_billing/access_actions"
require "recording_studio_billing/configuration"
require "recording_studio_billing/v1_contract"
require "recording_studio_billing/restricted_portal"
require "recording_studio_billing/routing"
require "recording_studio_billing/plans_page"
require "recording_studio_billing/billable"
require "recording_studio_billing/billing_admin_support"
require "recording_studio_billing/billing_admin_product_new"
require "recording_studio_billing/billing_operations_section"
require "recording_studio_billing/engine"

module RecordingStudioBilling
  RECORDABLE_TYPES = %w[
    RecordingStudioBilling::Account
    RecordingStudioBilling::Subscription
    RecordingStudioBilling::SubscriptionLine
    RecordingStudioBilling::Purchase
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

    def create_checkout_intent(...)
      CreateCheckoutIntent.call(...)
    end

    def execute_checkout_intent(...)
      ExecuteCheckoutIntent.call(...)
    end

    def project_completed_checkout_intent(...)
      ProjectCompletedCheckoutIntent.call(...)
    end

    def project_checkout_financial_records(...)
      ProjectCheckoutFinancialRecords.call(...)
    end

    def create_subscription_change_intent(...)
      CreateSubscriptionChangeIntent.call(...)
    end

    def apply_subscription_change_intent(...)
      ApplySubscriptionChangeIntent.call(...)
    end

    def create_refund_intent(...)
      CreateRefundIntent.call(...)
    end

    def create_adjustment_intent(...)
      CreateAdjustmentIntent.call(...)
    end

    def project_refund_intent(...)
      ProjectRefundIntent.call(...)
    end

    def project_adjustment_intent(...)
      ProjectAdjustmentIntent.call(...)
    end

    def apply_plan_update(...)
      ApplyPlanUpdate.call(...)
    end

    def project_entitlements(...)
      ProjectEntitlements.call(...)
    end

    def entitlement_access(...)
      EntitlementAccess.for(...)
    end

    def effective_entitlements(root_recording:)
      entitlement_access(root_recording:).to_h
    end

    def entitled?(root_recording:, feature_key:)
      entitlement_access(root_recording:).enabled?(feature_key)
    end

    def feature_value(root_recording:, feature_key:)
      entitlement_access(root_recording:).feature_value(feature_key)
    end

    def apply_default_free_entitlements!(...)
      ApplyDefaultFreeEntitlements.call(...)
    end

    # Soft by default: returns EnforceGate::Result. Pass mode: :hard to raise Denied.
    def enforce_gate!(root_recording:, gate_key:, subject: nil, quantity: 1, mode: :soft)
      mode = mode.to_sym
      raise ArgumentError, "gate mode must be :soft or :hard" unless %i[soft hard].include?(mode)

      EnforceGate.call(root_recording:, gate_key:, subject:, quantity:, raise_on_failure: mode == :hard)
    end

    def require_gate!(root_recording:, gate_key:, subject: nil, quantity: 1)
      enforce_gate!(root_recording:, gate_key:, subject:, quantity:, mode: :hard)
    end

    def gate_allowed?(root_recording:, gate_key:, subject: nil, quantity: 1)
      enforce_gate!(root_recording:, gate_key:, subject:, quantity:).allowed
    end

    def gate_status(...)
      GateStatus.call(...)
    end

    def gate_message(...)
      GateMessage.call(...)
    end

    def register_gate(...)
      configuration.register_gate(...)
    end

    def validate_gate_configuration!
      configuration.validate_gate_configuration!
    end

    def credit_balance(root_recording:, product_recording:)
      product_id = product_recording.respond_to?(:id) ? product_recording.id : product_recording
      entitlement_access(root_recording:).credit_balance(product_id)
    end

    def usage_total(root_recording:, usage_key:, from: nil, to: nil)
      entitlement_access(root_recording:).usage_total(usage_key.to_s, from:, to:)
    end

    def record_usage(...)
      RecordUsage.call(...)
    end

    def consume_credits(...)
      ConsumeCredits.call(...)
    end

    def rate_usage(...)
      RateUsage.call(...)
    end

    def create_rated_usage_settlement(...)
      CreateRatedUsageSettlement.call(...)
    end

    def execute_rated_usage_settlement(...)
      ExecuteRatedUsageSettlement.call(...)
    end

    def project_rated_usage_settlement(...)
      ProjectRatedUsageSettlement.call(...)
    end

    def reconcile_rated_usage_settlement(...)
      ReconcileRatedUsageSettlement.call(...)
    end

    def allocate_rated_usage(...)
      AllocateRatedUsage.call(...)
    end

    def expire_usage_credits(...)
      ExpireUsageCredits.call(...)
    end

    def calculate_overage(...)
      CalculateOverage.call(...)
    end

    def create_usage_correction(...)
      CreateUsageCorrection.call(...)
    end

    def apply_provider_webhook(...)
      ApplyProviderWebhook.call(...)
    end

    def apply_verified_provider_webhook(...)
      ApplyVerifiedProviderWebhook.call(...)
    end

    def reconcile_provider_command(...)
      ReconcileProviderCommand.call(...)
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

    def register_provider(key, adapter)
      configuration.provider_registry.register(key, adapter)
    end

    def register_builtin_providers!
      configuration.register_builtin_providers!
    end

    def register_webhook_actions!
      return unless defined?(RecordingStudioWebhooks)
      return if RecordingStudioWebhooks.actions.fetch(ApplyVerifiedProviderWebhook::ACTION_NAME)

      RecordingStudioWebhooks.register_action(
        ApplyVerifiedProviderWebhook::ACTION_NAME,
        ApplyVerifiedProviderWebhook,
        event: "*",
        source: "recording_studio_billing"
      )
    end

    def provider_adapter(key)
      configuration.provider_registry.fetch(key)
    end

    def register_tax_calculator(key, calculator)
      configuration.tax_calculator_registry.register(key, calculator)
    end

    def tax_calculator(key)
      configuration.tax_calculator_registry.fetch(key)
    end

    def calculate_tax(...)
      CalculateTax.call(...)
    end

    def recover_tax_calculation(...)
      RecoverTaxCalculation.call(...)
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
  end
end
