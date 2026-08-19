# frozen_string_literal: true

require "recording_studio_admin"

module RecordingStudioBilling
  class BillingCommercialSection < RecordingStudioAdmin::Section
    key "billing_commercial"
    icon :shopping_bag
    title "Products and pricing"
    subtitle "Products, prices, markets, and providers"
    blast_radius :site
    availability_scope :all

    link :products, text: "View products and pricing", url: ->(context) { context.admin_screen_path("billing_commercial") }
  end

  class BillingFinancialSection < RecordingStudioAdmin::Section
    key "billing_financial"
    icon :banknotes
    title "Financial records"
    subtitle "Commands, checkout, tax, and subscription activity"
    blast_radius :site
    availability_scope :all

    link :commands, text: "View financial commands", url: ->(context) { context.admin_screen_path("billing_financial") }
  end

  class BillingOperationsSection < RecordingStudioAdmin::Section
    key "billing_operations"
    icon :credit_card
    title "Billing operations"
    subtitle "Products, providers, tax, usage, and reconciliation"
    blast_radius :site
    availability_scope :all

    link :operations, text: "View billing operations", url: lambda { |context|
      context.admin_screen_path("billing_operations")
    }
  end

  class BillingAccountOperationsSection < RecordingStudioAdmin::Section
    key "billing_account_operations"
    icon :credit_card
    title "Account billing operations"
    subtitle "Account-scoped feature overrides"
    blast_radius :root
    availability_scope :all

    link :operations, text: "View account billing operations", url: lambda { |context|
      context.admin_screen_path("billing_feature_overrides")
    }
  end

  class BillingCommercialScreen < RecordingStudioAdmin::Screen
    key "billing_commercial"
    title "Products and pricing"
    blast_radius :site
    query { |_context| CommercialManifest.order(created_at: :desc) }
    filter :manifest_digest, label: "Manifest"
    filter :used_at, label: "Publication state"
  end

  class BillingFinancialScreen < RecordingStudioAdmin::Screen
    key "billing_financial"
    title "Financial records"
    blast_radius :site
    query { |_context| FinancialCommand.order(created_at: :desc) }
    filter :command_type, label: "Command type"
    filter :state, label: "State"
  end

  class BillingOperationsScreen < RecordingStudioAdmin::Screen
    key "billing_operations"
    title "Billing operations"
    blast_radius :site
    query { |_context| ReconciliationIssue.order(created_at: :desc) }
    filter :state, label: "State"
    filter :kind, label: "Issue type"
  end

  ADMIN_OPERATION_AREAS = {
    billing_provider_accounts: { section: "billing_commercial", title: "Provider accounts and capabilities",
                                 model: "ProviderAccount", scope: :current, filters: %i[adapter_key environment], columns: %i[key adapter_key environment capabilities] },
    billing_markets: { section: "billing_commercial", title: "Markets", model: "Market", scope: :current,
                       filters: %i[key default_currency_code], columns: %i[key default_currency_code priority global_fallback] },
    billing_products: { section: "billing_commercial", title: "Products", model: "Product", scope: :current,
                        filters: %i[key kind state], columns: %i[key kind state] },
    billing_options: { section: "billing_commercial", title: "Billing options", model: "BillingOption",
                       scope: :current, filters: %i[key recurrence pricing_model], columns: %i[key recurrence pricing_model checkout_policy] },
    billing_prices: { section: "billing_commercial", title: "Prices and publication", model: "Price", scope: :current,
                      filters: %i[key currency_code state], columns: %i[key amount_minor currency_code state] },
    billing_overage_prices: { section: "billing_commercial", title: "Overage prices", model: "OveragePrice",
                              scope: :current, filters: %i[key currency_code state], columns: %i[key amount_minor currency_code state] },
    billing_features: { section: "billing_commercial", title: "Features", model: "Feature", scope: :current,
                        filters: %i[key kind state], columns: %i[key kind state] },
    billing_product_rules: { section: "billing_commercial", title: "Product rules", model: "ProductRule",
                             scope: :current, filters: %i[key rule_type state], columns: %i[key rule_type state] },
    billing_manifests: { section: "billing_commercial", title: "Published manifests", model: "CommercialManifest",
                         filters: %i[manifest_digest used_at], columns: %i[manifest_digest used_at created_at] },
    billing_tax_calculations: { section: "billing_financial", title: "Tax calculations", model: "TaxCalculation",
                                filters: %i[calculator_key status], columns: %i[calculator_key status currency total_minor] },
    billing_usage_units: { section: "billing_operations", title: "Usage units", model: "UsageUnit", scope: :current,
                           filters: %i[key state], columns: %i[key state] },
    billing_meters: { section: "billing_operations", title: "Meters", model: "Meter", scope: :current,
                      filters: %i[key aggregation state], columns: %i[key aggregation state] },
    billing_rate_cards: { section: "billing_operations", title: "Rate cards", model: "RateCard", scope: :current,
                          filters: %i[key state], columns: %i[key state] },
    billing_rates: { section: "billing_operations", title: "Rates", model: "Rate", scope: :current,
                     filters: %i[key state], columns: %i[key conversion_numerator conversion_denominator state] },
    billing_cost_cards: { section: "billing_operations", title: "Cost cards", model: "CostCard", scope: :current,
                          filters: %i[key state], columns: %i[key state] },
    billing_cost_rates: { section: "billing_operations", title: "Cost rates", model: "CostRate", scope: :current,
                          filters: %i[key currency_code state], columns: %i[key amount_minor currency_code state] },
    billing_financial_commands: { section: "billing_financial", title: "Financial commands", model: "FinancialCommand",
                                  filters: %i[command_type state], columns: %i[command_type state provider_adapter_key created_at] },
    billing_financial_attempts: { section: "billing_financial", title: "Financial command attempts",
                                  model: "FinancialCommandAttempt", filters: %i[state provider_adapter_key], columns: %i[state provider_adapter_key created_at] },
    billing_checkout_intents: { section: "billing_financial", title: "Checkout intents", model: "CheckoutIntent",
                                filters: %i[state currency_code], columns: %i[state currency_code created_at] },
    billing_subscriptions: { section: "billing_operations", title: "Subscriptions", model: "Subscription",
                             scope: :current, filters: %i[state currency_code], columns: %i[identifier state currency_code] },
    billing_purchases: { section: "billing_operations", title: "Purchases", model: "Purchase",
                         filters: %i[mode currency_code], columns: %i[mode amount_minor currency_code] },
    billing_subscription_lines: { section: "billing_operations", title: "Plan lines", model: "SubscriptionLine",
                                  scope: :current, filters: %i[mode currency_code], columns: %i[line_key mode amount_minor currency_code] },
    billing_feature_overrides: { section: "billing_account_operations", title: "Feature overrides", model: "FeatureOverride",
                                 scope: :current, filters: %i[key state], columns: %i[key state] },
    billing_usage_credits: { section: "billing_operations", title: "Usage credits", model: "UsageCreditGrant",
                             filters: %i[credit_key grant_kind], columns: %i[credit_key grant_kind quantity remaining_quantity] },
    billing_usage_periods: { section: "billing_operations", title: "Usage periods", model: "UsagePeriod",
                             filters: %i[usage_key state], columns: %i[usage_key state starts_at ends_at] },
    billing_overage_calculations: { section: "billing_operations", title: "Overage calculations",
                                    model: "OverageCalculation", filters: %i[currency_code], columns: %i[excess_quantity amount_minor currency_code] },
    billing_invoices: { section: "billing_financial", title: "Invoices", model: "Invoice",
                        filters: %i[state currency_code], columns: %i[state total_minor currency_code issued_at] },
    billing_payments: { section: "billing_financial", title: "Payments", model: "Payment",
                        filters: %i[state currency_code], columns: %i[state amount_minor currency_code recorded_at] },
    billing_refunds: { section: "billing_financial", title: "Refunds", model: "Refund", filters: %i[currency_code],
                       columns: %i[amount_minor currency_code recorded_at] },
    billing_financial_adjustments: { section: "billing_financial", title: "Financial adjustments",
                                     model: "FinancialAdjustment", filters: %i[kind currency_code], columns: %i[kind amount_minor currency_code recorded_at] },
    billing_plan_updates: { section: "billing_operations", title: "Plan updates", model: "PlanUpdate", scope: :current,
                            filters: %i[key execution_state state], columns: %i[key execution_state state] },
    billing_plan_update_runs: { section: "billing_operations", title: "Plan update runs", model: "PlanUpdateRun",
                                filters: %i[state idempotency_key], columns: %i[state idempotency_key scheduled_at] },
    billing_plan_update_applications: { section: "billing_operations", title: "Plan update applications",
                                        model: "PlanUpdateApplication", filters: %i[state], columns: %i[state created_at] },
    billing_webhook_effects: { section: "billing_operations", title: "Webhook effects", model: "WebhookEffect",
                               filters: %i[provider_adapter_key handler_name action_version], columns: %i[provider_adapter_key event_id handler_name action_version] },
    billing_reconciliation_issues: { section: "billing_operations", title: "Reconciliation issues",
                                     model: "ReconciliationIssue", filters: %i[state kind], columns: %i[authority kind state created_at] }
  }.freeze

  ADMIN_INVESTIGATION_RESOURCES = %w[
    billing_provider_accounts
    billing_financial_commands
    billing_webhook_effects
    billing_reconciliation_issues
  ].freeze

  ADMIN_COMMERCIAL_OPERATION_NAMES = {
    "billing_provider_accounts" => "provider_account",
    "billing_markets" => "market",
    "billing_products" => "product",
    "billing_options" => "billing_option",
    "billing_prices" => "price",
    "billing_overage_prices" => "overage_price",
    "billing_features" => "feature",
    "billing_product_rules" => "product_rule",
    "billing_usage_units" => "usage_unit",
    "billing_meters" => "meter",
    "billing_rate_cards" => "rate_card",
    "billing_rates" => "rate",
    "billing_cost_cards" => "cost_card",
    "billing_cost_rates" => "cost_rate"
  }.freeze

  ADMIN_OPERATION_SCREEN_CLASSES = ADMIN_OPERATION_AREAS.map do |key, definition|
    Class.new(RecordingStudioAdmin::Screen) do
      key key.to_s
      title definition.fetch(:title)
      blast_radius(key.to_s == "billing_feature_overrides" ? :root : :site)
      query do |_context|
        model = "RecordingStudioBilling::#{definition.fetch(:model)}".constantize
        relation = definition[:scope] == :current ? model.with_current_recording : model.all
        relation.order(created_at: :desc)
      end
      definition.fetch(:filters).each { |filter_key| filter filter_key, label: filter_key.to_s.humanize }
      table do
        title definition.fetch(:title)
        definition.fetch(:columns).each { |column| column column }
        default_columns(*definition.fetch(:columns))
        default_sort :created_at, direction: :desc
        admin_action key, :investigate if ADMIN_INVESTIGATION_RESOURCES.include?(key.to_s)
        admin_action key, :publish if key.to_s == "billing_prices"
        admin_action key, :preview if key.to_s == "billing_plan_updates"
        admin_action key, :confirm if key.to_s == "billing_plan_update_runs"
        admin_action key, :apply if key.to_s == "billing_plan_update_runs"
        admin_action key, :reconcile if key.to_s == "billing_financial_commands"
        admin_action key, :create if ADMIN_COMMERCIAL_OPERATION_NAMES.key?(key.to_s)
        admin_action key, :revise if ADMIN_COMMERCIAL_OPERATION_NAMES.key?(key.to_s)
        admin_action key, :retire if ADMIN_COMMERCIAL_OPERATION_NAMES.key?(key.to_s)
        admin_action key, :refund if key.to_s == "billing_payments"
        admin_action key, :adjust if key.to_s == "billing_invoices"
        admin_action key, :create if key.to_s == "billing_feature_overrides"
        admin_action key, :revise if key.to_s == "billing_feature_overrides"
        admin_action key, :revoke if key.to_s == "billing_feature_overrides"
        admin_action key, :supersede if key.to_s == "billing_feature_overrides"
      end
    end
  end.freeze

  ADMIN_OPERATION_RESOURCE_CLASSES = ADMIN_OPERATION_AREAS.map do |key, definition|
    Class.new(RecordingStudioAdmin::Resource) do
      key key.to_s
      section definition.fetch(:section)
      title definition.fetch(:title)
      blast_radius(key.to_s == "billing_feature_overrides" ? :root : :site)
      if ADMIN_INVESTIGATION_RESOURCES.include?(key.to_s)
        action :investigate,
               text: "Investigate",
               url: ->(_record, context) { context.admin_screen_path(key.to_s) },
               required_role: :view,
               blast_radius: :site
      end
      {
        "billing_prices" => { action: :publish, operation: "publish_price", text: "Publish",
                              confirm: "Publish this price and its validated commercial graph?" },
        "billing_plan_updates" => { action: :preview, operation: "preview_plan_update", text: "Preview",
                                    confirm: "Create a plan update preview?" },
        "billing_plan_update_runs_confirm" => { action: :confirm, operation: "confirm_plan_update", text: "Confirm",
                                                confirm: "Confirm this plan update preview?" },
        "billing_plan_update_runs" => { action: :apply, operation: "apply_plan_update", text: "Apply",
                                        confirm: "Apply this confirmed plan update run?" },
        "billing_financial_commands" => { action: :reconcile, operation: "reconcile_command", text: "Reconcile",
                                          confirm: "Retrieve and reconcile this provider command?" }
      }.each do |resource_key, operation|
        next unless resource_key.delete_suffix("_confirm") == key.to_s

        action operation.fetch(:action),
               text: operation.fetch(:text), method: :post, confirm: operation.fetch(:confirm), required_role: :admin,
               blast_radius: :site,
               url: lambda { |record, context|
                 engine_path = RecordingStudioBilling::Engine.routes.url_helpers.admin_operation_path(
                   operation: operation.fetch(:operation), id: record.id
                 )
                 mount_path = if context.controller.respond_to?(:main_app)
                                context.controller.main_app.recording_studio_billing_path
                              else
                                "/billing"
                              end
                 "#{mount_path.to_s.chomp('/')}#{engine_path}"
               }
      end
      if (operation_name = ADMIN_COMMERCIAL_OPERATION_NAMES[key.to_s])
        action :create,
               text: "Create draft", method: :post, required_role: :admin, blast_radius: :site,
               visible_if: ->(_record, context) { context.params["parent_recording_id"].present? },
               url: lambda { |_record, context|
                 parent_recording_id = context.params.fetch("parent_recording_id")
                 engine_path = RecordingStudioBilling::Engine.routes.url_helpers.admin_operations_create_path(
                   operation: "create_draft_#{operation_name}", parent_recording_id:
                 )
                 mount_path = if context.controller.respond_to?(:main_app)
                                context.controller.main_app.recording_studio_billing_path
                              else
                                "/billing"
                              end
                 "#{mount_path.to_s.chomp('/')}#{engine_path}"
               }
        actions = {
          revise: { operation: "revise_#{operation_name}", text: "Revise" }
        }
        actions[:retire] = { operation: "retire_#{operation_name}", text: "Retire" }
        actions.each do |action_name, operation|
          action action_name,
                 text: operation.fetch(:text), method: :post, required_role: :admin, blast_radius: :site,
                 url: lambda { |record, context|
                   operation_path = RecordingStudioBilling::Engine.routes.url_helpers.admin_operation_path(
                     operation: operation.fetch(:operation), id: record.id
                   )
                   mount_path = if context.controller.respond_to?(:main_app)
                                  context.controller.main_app.recording_studio_billing_path
                                else
                                  "/billing"
                                end
                   "#{mount_path.to_s.chomp('/')}#{operation_path}"
                 }
        end
      end
      if key.to_s == "billing_feature_overrides"
        action :create, text: "Create override", method: :post, required_role: :admin, blast_radius: :root,
                        visible_if: ->(_record, context) { context.params["account_recording_id"].present? },
                        url: lambda { |_record, context|
                          engine_path = RecordingStudioBilling::Engine.routes.url_helpers.admin_operations_create_path(
                            operation: "create_feature_override", account_recording_id: context.params.fetch("account_recording_id")
                          )
                          mount_path = context.controller.respond_to?(:main_app) ? context.controller.main_app.recording_studio_billing_path : "/billing"
                          "#{mount_path.to_s.chomp('/')}#{engine_path}"
                        }
        {
          revise: { operation: "revise_feature_override", text: "Revise" },
          revoke: { operation: "revoke_feature_override", text: "Revoke" },
          supersede: { operation: "supersede_feature_override", text: "Supersede" }
        }.each do |action_name, operation|
          action action_name, text: operation.fetch(:text), method: :post, required_role: :admin, blast_radius: :root,
                              url: lambda { |record, context|
                                engine_path = RecordingStudioBilling::Engine.routes.url_helpers.admin_operation_path(
                                  operation: operation.fetch(:operation), id: record.id
                                )
                                mount_path = context.controller.respond_to?(:main_app) ? context.controller.main_app.recording_studio_billing_path : "/billing"
                                "#{mount_path.to_s.chomp('/')}#{engine_path}"
                              }
        end
      end
      {
        "billing_payments" => { action: :refund, operation: "create_refund_intent", text: "Create refund intent" },
        "billing_invoices" => { action: :adjust, operation: "create_adjustment_intent", text: "Create adjustment intent" }
      }.fetch(key.to_s, {}).then do |operation|
        next if operation.empty?

        action operation.fetch(:action), text: operation.fetch(:text), method: :post, required_role: :admin,
                                         blast_radius: :site,
                                         url: lambda { |record, context|
                                           engine_path = RecordingStudioBilling::Engine.routes.url_helpers.admin_operation_path(
                                             operation: operation.fetch(:operation), id: record.id
                                           )
                                           mount_path = if context.controller.respond_to?(:main_app)
                                                          context.controller.main_app.recording_studio_billing_path
                                                        else
                                                          "/billing"
                                                        end
                                           "#{mount_path.to_s.chomp('/')}#{engine_path}"
                                         }
      end
    end
  end.freeze

  class BillingCommercialResource < RecordingStudioAdmin::Resource
    key "billing_commercial"
    section "billing_commercial"
    title "Products and pricing"
    blast_radius :site
  end

  class BillingFinancialResource < RecordingStudioAdmin::Resource
    key "billing_financial"
    section "billing_financial"
    title "Financial records"
    blast_radius :site
  end

  class BillingOperationsResource < RecordingStudioAdmin::Resource
    key "billing_operations"
    section "billing_operations"
    title "Billing operations"
    blast_radius :site
  end
end
