# frozen_string_literal: true

module RecordingStudioBilling
  class BillingController < ApplicationController
    before_action :authorize_billing_screen!

    def index
      @subscriptions = Subscription.for_root(root_recording).order(created_at: :desc)
      @checkout_intents = CheckoutIntent.for_root(root_recording).order(created_at: :desc)
      @presenter = billing_presenter(:overview, subscriptions: @subscriptions, checkout_intents: @checkout_intents)
      @billing_page = :overview
    end

    def plan
      @subscriptions = Subscription.for_root(root_recording).order(created_at: :desc)
      @presenter = billing_presenter(
        :subscriptions, subscriptions: @subscriptions, account_recording:,
                        eligible_options: customer_offers_for("plan"),
                        change_intents: SubscriptionChangeIntent.where(root_recording:, account_recording:).order(created_at: :desc)
      )
      @billing_page = :subscriptions
      render :index
    end

    def addons
      @purchases = Purchase.where(root_recording:, account_recording:).includes(:effects).order(created_at: :desc)
      @presenter = billing_presenter(:addons, purchases: @purchases,
                                              eligible_options: customer_offers_for("addon", "credit_pack"))
    end

    def usage
      @entitlements = RecordingStudioBilling.effective_entitlements(root_recording:)
      scope = { root_recording:, account_recording: }
      @presenter = billing_presenter(
        :usage, entitlements: @entitlements,
                periods: UsagePeriod.where(scope).includes(:usage_allowance_policies).order(starts_at: :desc),
                credit_grants: UsageCreditGrant.where(scope).order(effective_at: :desc),
                allocations: UsageAllocation.where(scope).includes(:usage_period, :overage_calculation,
                                                                   :usage_credit_allocations).order(created_at: :desc)
      )
    end

    def invoices
      @invoices = Invoice.where(root_recording:, account_recording:).order(issued_at: :desc)
      @adjustments = FinancialAdjustment.joins(:invoice).merge(Invoice.where(root_recording:, account_recording:))
      @presenter = billing_presenter(
        :invoices, invoices: @invoices, adjustments: @adjustments,
                   refunds: Refund.joins(:payment).merge(Payment.where(root_recording:, account_recording:)),
                   refund_intents: RefundIntent.where(root_recording:, account_recording:).includes(:refund, :financial_command),
                   adjustment_intents: AdjustmentIntent.where(root_recording:,
                                                              account_recording:).includes(:financial_adjustment, :financial_command)
      )
    end

    def payments
      @payments = Payment.where(root_recording:, account_recording:).order(recorded_at: :desc)
      @refunds = Refund.joins(:payment).merge(Payment.where(root_recording:, account_recording:))
      @presenter = billing_presenter(
        :payments, payments: @payments, refunds: @refunds,
                   refund_intents: RefundIntent.where(root_recording:, account_recording:).includes(:refund, :financial_command)
      )
    end

    def settings
      @presenter = billing_presenter(:settings, account: account_recording.recordable)
    end

    def update_settings
      authorize_billing_action!(:edit_billing_settings)
      RecordingStudioBilling::UpdateAccountPreferences.call(
        root_recording:, account_recording:, attributes: settings_params, actor: current_billing_actor
      )
      redirect_to settings_billing_path(root_recording_id: root_recording.id), notice: "Billing settings updated."
    rescue ArgumentError, ActionController::ParameterMissing
      redirect_to settings_billing_path(root_recording_id: root_recording.id),
                  alert: "Billing settings could not be updated."
    end

    private

    def authorize_billing_screen!
      action = case action_name
               when "invoices" then :view_invoices
               when "payments" then :view_payments
               else :view_billing
               end
      authorize_billing_action!(action)
    end

    def billing_presenter(page, **attributes)
      presenter_class = RecordingStudioBilling.configuration.billing_presenter_for(
        page, "RecordingStudioBilling::#{page.to_s.camelize}Presenter".constantize
      )
      presenter_class.new(root_recording:, **attributes)
    end

    def customer_offers_for(*kinds)
      CustomerOfferEligibility.call(root_recording:, account_recording:, kinds:)
    end

    def settings_params
      params.require(:account).permit(
        :name, :contact_email, :billing_country_code, :billing_currency_code, :locale, :time_zone,
        :tax_location_country_code, :tax_location_region_code, :tax_location_postal_code
      )
    end
  end
end
