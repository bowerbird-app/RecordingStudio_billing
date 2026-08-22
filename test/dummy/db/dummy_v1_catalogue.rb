# frozen_string_literal: true

require_relative "../../../app/services/recording_studio_billing/fake_tax_calculator"

# Idempotent V1 demonstration catalogue for the dummy host. Seeds exactly one
# Workspace, Admin root, billing account, and billing admin, then publishes
# products, prices, and journey fixtures through the same services production
# uses. Reset the dummy database if a published record no longer matches.
class DummyV1Catalogue
  PRODUCT_DISPLAY_NAMES = {
    "demo_free_plan" => "Free plan",
    "demo_monthly_plan" => "Pro",
    "demo_annual_plan" => "Pro yearly",
    "stripe_test_monthly_plan" => "Starter"
  }.freeze

  Result = Struct.new(
    :user, :workspace, :admin_root, :root_recording, :admin_root_recording,
    :account, :billing_admin, :fake_provider, :stripe_test_provider,
    keyword_init: true
  )

  MARKET_SPECS = {
    "demo_us_market" => { countries: ["US"], currency: "USD", amount: 1_200, global: false },
    "demo_uk_market" => { countries: ["GB"], currency: "GBP", amount: 900, global: false },
    "demo_it_market" => { countries: ["IT"], currency: "EUR", amount: 1_000, global: false },
    "demo_de_market" => { countries: ["DE"], currency: "EUR", amount: 1_100, global: false },
    "demo_global_market" => { countries: [], currency: "USD", amount: 1_300, global: true }
  }.freeze

  PLAN_MARKET_AMOUNTS = {
    "demo_free_plan" => {
      "demo_us_market" => { amount: 0, currency: "USD" }
    },
    "demo_monthly_plan" => {
      "demo_us_market" => { amount: 4_900, currency: "USD" },
      "demo_uk_market" => { amount: 3_900, currency: "GBP" },
      "demo_it_market" => { amount: 4_500, currency: "EUR" },
      "demo_de_market" => { amount: 4_700, currency: "EUR" },
      "demo_global_market" => { amount: 5_100, currency: "USD" }
    },
    "demo_annual_plan" => {
      "demo_us_market" => { amount: 49_000, currency: "USD" },
      "demo_uk_market" => { amount: 39_000, currency: "GBP" },
      "demo_it_market" => { amount: 45_000, currency: "EUR" },
      "demo_de_market" => { amount: 47_000, currency: "EUR" },
      "demo_global_market" => { amount: 51_000, currency: "USD" }
    }
  }.freeze

  def self.call
    new.call
  end

  def call
    RecordingStudioBilling.configuration.product_display_names = PRODUCT_DISPLAY_NAMES
    ActiveRecord::Base.connection.clear_query_cache
    @user = User.find_or_create_by!(email: "admin@admin.com") do |user|
      user.password = "Password"
      user.password_confirmation = "Password"
    end
    @workspace = Workspace.find_or_create_by!(name: "Studio Workspace")
    @admin_root = AdminRoot.find_or_create_by!(name: "Billing Administration")
    register_tax_calculators!
    with_actor { seed_graph! }
    Result.new(
      user: @user, workspace: @workspace, admin_root: @admin_root,
      root_recording: @root_recording, admin_root_recording: @admin_root_recording,
      account: @account, billing_admin: @billing_admin,
      fake_provider: @fake_provider, stripe_test_provider: @stripe_test_provider
    )
  end

  private

  def with_actor
    previous = Current.actor
    Current.actor = @user
    yield
  ensure
    Current.actor = previous
  end

  def seed_graph!
    seed_hierarchy!
    seed_providers!
    seed_markets_and_checkout_prices!
    seed_metered_service!
    seed_plans_addons_and_credit_pack!
    seed_rules_and_review_update!
    publish_unpublished_prices!
    refresh_published_records!
    seed_features!
    apply_default_free_entitlements!
    seed_sample_projects!
    seed_stripe_probe!
    seed_customer_journeys!
    seed_stripe_user_flow!
  end

  def seed_hierarchy!
    @root_recording = RecordingStudio.root_recording_for(@workspace)
    @admin_root_recording = RecordingStudio.root_recording_for(@admin_root)
    RecordingStudioBilling.ensure_account(root_recording: @root_recording, name: "Studio Account")
    RecordingStudioBilling.ensure_billing_admin(root_recording: @admin_root_recording, key: "billing")
    @root_recording = RecordingStudio::Recording.unscoped.find(@root_recording.id)
    @admin_root_recording = RecordingStudio::Recording.unscoped.find(@admin_root_recording.id)
    account_recording = RecordingStudio::Recording.unscoped.find_by!(
      root_recording: @root_recording, parent_recording: @root_recording,
      recordable_type: "RecordingStudioBilling::Account", trashed_at: nil
    )
    billing_admin_recording = RecordingStudio::Recording.unscoped.find_by!(
      root_recording: @admin_root_recording, parent_recording: @admin_root_recording,
      recordable_type: "RecordingStudioBilling::BillingAdmin", trashed_at: nil
    )
    @account = account_recording.recordable
    @billing_admin = billing_admin_recording.recordable
    seed_customer_access!
  end

  def seed_customer_access!
    bootstrap_owner_access!(@root_recording)
    bootstrap_owner_access!(@admin_root_recording)
    unless RecordingStudioAccessible.authorized?(actor: @user, recording: @root_recording, role: :edit)
      raise "dummy catalogue workspace billing access was not granted"
    end
    unless RecordingStudioAccessible.authorized?(actor: @user, recording: @admin_root_recording, role: :view)
      raise "dummy catalogue admin root access was not granted"
    end
  end

  def bootstrap_owner_access!(recording)
    result = RecordingStudioAccessible.bootstrap_owner_access!(
      recording: recording,
      actor: @user
    )
    return if result.success?

    raise "dummy catalogue could not bootstrap owner access: #{result.error}"
  end

  def seed_providers!
    RecordingStudioBilling.register_builtin_providers!
    @fake_provider = find_or_record(
      RecordingStudioBilling::ProviderAccount,
      "demo_fake_provider",
      billing_admin_recording: @billing_admin.recording, adapter_key: "fake",
      name: "Demo fake provider", environment: "test", configuration: {}, capabilities: [],
      supported_markets: %w[US GB IT DE], supported_currencies: %w[USD GBP EUR]
    )
    @stripe_test_provider = find_or_record(
      RecordingStudioBilling::ProviderAccount,
      "demo_stripe_test_provider",
      billing_admin_recording: @billing_admin.recording, adapter_key: "stripe",
      name: "Demo Stripe test provider", environment: "test",
      configuration: { "display_name" => "Stripe test" }, capabilities: [],
      supported_markets: %w[US GB IT DE], supported_currencies: %w[USD GBP EUR]
    )
  end

  def seed_markets_and_checkout_prices!
    product = find_or_record(
      RecordingStudioBilling::Product, "demo_checkout_product",
      provider_account_recording: @fake_provider.recording, kind: "service", feature_values: {}
    )
    option = find_or_record(
      RecordingStudioBilling::BillingOption, "demo_checkout_option",
      parent: product, product_recording: product.recording, recurrence: "one_time",
      quantity_mode: "fixed", default_quantity: 1, pricing_model: "flat",
      collection_method: "automatic", payment_terms_days: 0, trial_days: 0,
      proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed",
      tax_policy: "exclusive"
    )
    @checkout_option = option
    @markets = {}
    @checkout_prices = MARKET_SPECS.map do |market_key, spec|
      market = find_or_record(
        RecordingStudioBilling::Market, market_key,
        provider_account_recording: @fake_provider.recording, country_codes: spec[:countries],
        country_groups: {}, allowed_currency_codes: [spec[:currency]],
        default_currency_code: spec[:currency], priority: 10, specificity: 1,
        regional_country_codes: [], global_fallback: spec[:global], ppa_policy: "standard",
        rounding_policy: "half_up", tax_presentation_policy: "exclusive",
        verification_policy: "requote"
      )
      @markets[market_key] = market
      find_or_record(
        RecordingStudioBilling::Price, "#{market_key}_price",
        parent: option, billing_option_recording: option.recording,
        market_recording: market.recording, amount_minor: spec[:amount],
        currency_code: spec[:currency], currency_exponent: 2, pricing_model: "flat",
        version: 1, scope: "market"
      )
    end
  end

  def seed_metered_service!
    @usage_product = find_or_record(
      RecordingStudioBilling::Product, "demo_usage_product",
      provider_account_recording: @fake_provider.recording, kind: "service",
      feature_values: { "demo_api_calls" => 5 }
    )
    assert_record!(@usage_product, kind: "service")
    @usage_option = find_or_record(
      RecordingStudioBilling::BillingOption, "demo_usage_option",
      parent: @usage_product, product_recording: @usage_product.recording,
      recurrence: "recurring", interval: "month", interval_count: 1, quantity_mode: "fixed",
      default_quantity: 1, pricing_model: "per_unit", collection_method: "automatic",
      payment_terms_days: 0, trial_days: 0, proration_policy: "none",
      lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"
    )
    @usage_unit = find_or_record(
      RecordingStudioBilling::UsageUnit, "demo_api_call",
      provider_account_recording: @fake_provider.recording
    )
    @meter = find_or_record(
      RecordingStudioBilling::Meter, "demo_api_calls",
      usage_unit_recording: @usage_unit.recording, aggregation: "sum"
    )
    rate_card = find_or_record(
      RecordingStudioBilling::RateCard, "demo_usage_rates",
      provider_account_recording: @fake_provider.recording
    )
    find_or_record(
      RecordingStudioBilling::Rate, "demo_api_call_conversion",
      parent: rate_card, rate_card_recording: rate_card.recording,
      usage_unit_recording: @usage_unit.recording, conversion_numerator: 1,
      conversion_denominator: 1
    )
    cost_card = find_or_record(
      RecordingStudioBilling::CostCard, "demo_usage_costs",
      provider_account_recording: @fake_provider.recording
    )
    find_or_record(
      RecordingStudioBilling::CostRate, "demo_api_call_cost",
      parent: cost_card, cost_card_recording: cost_card.recording,
      usage_unit_recording: @usage_unit.recording, amount_minor: 2, currency_code: "USD",
      currency_exponent: 2
    )
    us_market = @markets.fetch("demo_us_market")
    @usage_price = find_or_record(
      RecordingStudioBilling::Price, "demo_usage_us_price",
      parent: @usage_option, billing_option_recording: @usage_option.recording,
      market_recording: us_market.recording, amount_minor: 100, currency_code: "USD",
      currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "market"
    )
    @overage_price = find_or_record(
      RecordingStudioBilling::OveragePrice, "demo_usage_api_overage",
      parent: @usage_option, billing_option_recording: @usage_option.recording,
      market_recording: us_market.recording, usage_unit_recording: @usage_unit.recording,
      amount_minor: 5, currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit",
      version: 1, scope: "market", review_threshold_minor: 50, hard_threshold_minor: 200,
      maximum_period_liability_minor: 1_000, maximum_submission_minor: 500
    )
  end

  def seed_plans_addons_and_credit_pack!
    @catalogue = {}
    plan_option_specs.each do |key, spec|
      product = find_or_record(
        RecordingStudioBilling::Product, key,
        provider_account_recording: @fake_provider.recording, kind: spec[:kind],
        feature_values: spec[:feature_values]
      )
      option = find_or_record(
        RecordingStudioBilling::BillingOption, "#{key}_option",
        parent: product, product_recording: product.recording, recurrence: spec[:recurrence],
        interval: spec[:interval], interval_count: spec[:interval] && 1,
        quantity_mode: spec[:quantity_mode], minimum_quantity: spec[:minimum_quantity],
        maximum_quantity: spec[:maximum_quantity], default_quantity: 1, pricing_model: "flat",
        collection_method: "automatic", payment_terms_days: 0, trial_days: spec[:trial_days],
        proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed",
        tax_policy: "exclusive"
      )
      assert_record!(option, trial_days: spec[:trial_days])
      prices = PLAN_MARKET_AMOUNTS.fetch(key, { "demo_us_market" => { amount: spec[:amount], currency: "USD" } })
      price_records = prices.map do |market_key, price_spec|
        find_or_record(
          RecordingStudioBilling::Price, "#{key}_#{market_key.delete_prefix('demo_').delete_suffix('_market')}_price",
          parent: option, billing_option_recording: option.recording,
          market_recording: @markets.fetch(market_key).recording,
          amount_minor: price_spec[:amount], currency_code: price_spec[:currency],
          currency_exponent: 2, pricing_model: "flat", version: 1, scope: "market"
        )
      end
      @catalogue[key] = {
        product: product, option: option, prices: price_records,
        us_price: price_records.find { |price| price.key.end_with?("_us_price") } || price_records.first
      }
    end
  end

  def plan_option_specs
    {
      "demo_free_plan" => {
        amount: 0, recurrence: "recurring", interval: "month", kind: "plan",
        trial_days: 0, quantity_mode: "fixed", feature_values: { "demo_projects" => 2 }
      },
      "demo_monthly_plan" => {
        amount: 4_900, recurrence: "recurring", interval: "month", kind: "plan",
        trial_days: 0, quantity_mode: "fixed", feature_values: { "demo_projects" => 10 }
      },
      "demo_annual_plan" => {
        amount: 49_000, recurrence: "recurring", interval: "year", kind: "plan",
        trial_days: 14, quantity_mode: "fixed", feature_values: { "demo_projects" => 25 }
      },
      "demo_quantity_addon" => {
        amount: 1_000, recurrence: "recurring", interval: "month", kind: "addon",
        trial_days: 0, quantity_mode: "adjustable", minimum_quantity: 1, maximum_quantity: 25,
        feature_values: {}
      },
      "demo_credit_pack" => {
        amount: 2_500, recurrence: "one_time", interval: nil, kind: "credit_pack",
        trial_days: 0, quantity_mode: "fixed", feature_values: { "demo_api_calls" => 1_000 }
      }
    }
  end

  def seed_rules_and_review_update!
    find_or_record(
      RecordingStudioBilling::ProductRule, "demo_addon_requires_plan",
      product_recording_id: @catalogue.fetch("demo_quantity_addon").fetch(:product).recording.id,
      target_product_recording_id: @catalogue.fetch("demo_monthly_plan").fetch(:product).recording.id,
      rule_type: "requires", conditions: { "country_code" => "US" }
    )
    monthly_option = @catalogue.fetch("demo_monthly_plan").fetch(:option)
    @monthly_plan_update = find_or_record(
      RecordingStudioBilling::PlanUpdate, "demo_monthly_plan_review",
      billing_option_recording: monthly_option.recording
    )
  end

  def publish_unpublished_prices!
    price_groups.each do |prices|
      ids = prices.filter_map do |price|
        current = RecordingStudioBilling::Price.with_current_recording.find_by(key: price.key)
        current.recording.id unless current.state == "published"
      end
      next if ids.empty?

      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: @admin_root_recording, price_recording_ids: ids, actor: @user
      )
    end
  end

  def price_groups
    [@checkout_prices, [@usage_price]] + @catalogue.values.map { |entry| entry.fetch(:prices) }
  end

  def refresh_published_records!
    @fake_provider = refresh(@fake_provider)
    @stripe_test_provider = refresh(@stripe_test_provider)
    @usage_product = refresh(@usage_product)
    @usage_option = refresh(@usage_option)
    @usage_unit = refresh(@usage_unit)
    @meter = refresh(@meter)
    @usage_price = refresh(@usage_price)
    @overage_price = refresh(@overage_price)
    @checkout_option = refresh(@checkout_option)
    @catalogue.transform_values! do |entry|
      {
        product: refresh(entry.fetch(:product)),
        option: refresh(entry.fetch(:option)),
        prices: entry.fetch(:prices).map { |price| refresh(price) },
        us_price: refresh(entry.fetch(:us_price))
      }
    end
    @monthly_plan_update = refresh(@monthly_plan_update)
  end

  def seed_features!
    monthly = @catalogue.fetch("demo_monthly_plan")
    free = @catalogue.fetch("demo_free_plan")
    addon = @catalogue.fetch("demo_quantity_addon")
    credit_pack = @catalogue.fetch("demo_credit_pack")
    @priority_feature = find_or_record(
      RecordingStudioBilling::Feature, "demo_priority_support",
      parent: monthly.fetch(:product), product_recording: monthly.fetch(:product).recording,
      kind: "boolean", definition: {}, unique_by: :product
    )
    @projects_feature = find_or_record(
      RecordingStudioBilling::Feature, "demo_projects",
      parent: free.fetch(:product), product_recording: free.fetch(:product).recording,
      kind: "limit", definition: {}, unique_by: :product
    )
    find_or_record(
      RecordingStudioBilling::Feature, "demo_projects",
      parent: monthly.fetch(:product), product_recording: monthly.fetch(:product).recording,
      kind: "limit", definition: {}, unique_by: :product
    )
    annual = @catalogue.fetch("demo_annual_plan")
    find_or_record(
      RecordingStudioBilling::Feature, "demo_projects",
      parent: annual.fetch(:product), product_recording: annual.fetch(:product).recording,
      kind: "limit", definition: {}, unique_by: :product
    )
    find_or_record(
      RecordingStudioBilling::Feature, "demo_priority_support",
      parent: addon.fetch(:product), product_recording: addon.fetch(:product).recording,
      kind: "boolean", definition: {}, unique_by: :product
    )
    @usage_feature = find_or_record(
      RecordingStudioBilling::Feature, "demo_api_calls",
      parent: @usage_product, product_recording: @usage_product.recording,
      kind: "allowance", definition: {}, unique_by: :product
    )
    assert_record!(@usage_feature, kind: "allowance")
    find_or_record(
      RecordingStudioBilling::Feature, "demo_api_calls",
      parent: credit_pack.fetch(:product), product_recording: credit_pack.fetch(:product).recording,
      kind: "allowance", definition: {}, unique_by: :product
    )
    unpublished = [@priority_feature, @usage_feature, @projects_feature].reject { |feature| feature.state == "published" }
    return if unpublished.empty?

    [[monthly.fetch(:us_price)], [free.fetch(:us_price)], [@usage_price], [credit_pack.fetch(:us_price)]].each do |prices|
      RecordingStudioBilling::CommercialPublisher.publish!(
        root_recording: @admin_root_recording,
        price_recording_ids: prices.map { |price| price.recording.id },
        actor: @user
      )
    end
    @priority_feature = refresh(@priority_feature)
    @usage_feature = refresh(@usage_feature)
    @projects_feature = refresh(@projects_feature)
  end

  def apply_default_free_entitlements!
    account_recording = RecordingStudio::Recording.unscoped.find_by!(
      root_recording: @root_recording, parent_recording: @root_recording,
      recordable_type: "RecordingStudioBilling::Account", trashed_at: nil
    )
    RecordingStudioBilling.apply_default_free_entitlements!(
      root_recording: @root_recording, account_recording: account_recording
    )
  end

  def seed_sample_projects!
    return if Project.for_root(@root_recording).exists?

    @root_recording.record(Project) { |project| project.name = "Starter project" }
  end

  def seed_stripe_probe!
    return if RecordingStudioBilling::FinancialCommand.exists?(root_recording: @root_recording,
                                                               local_idempotency_key: "seed:stripe-configuration-probe")
    return if RecordingStudioBilling.configuration.stripe_credential_resolver.present?

    RecordingStudioBilling.execute_financial_command(
      root_recording: @root_recording, account_recording: @account.recording,
      command_type: "provider_configuration_check", local_idempotency_key: "seed:stripe-configuration-probe",
      provider_account_recording: @stripe_test_provider.recording, provider_key: "stripe",
      request: { "purpose" => "dummy_stripe_configuration_probe" }
    )
  end

  def seed_stripe_user_flow!
    return unless DummyStripeTestCredentials.user_flow_enabled?

    workspace = Workspace.find_or_create_by!(name: "Stripe Test Workspace")
    workspace_root = RecordingStudio.root_recording_for(workspace)
    RecordingStudioBilling.ensure_account(root_recording: workspace_root, name: "Stripe Test Account")
    grant_stripe_workspace_access!(workspace_root)

    market = find_or_record(
      RecordingStudioBilling::Market, "stripe_test_us_market",
      provider_account_recording: @stripe_test_provider.recording, country_codes: ["US"],
      country_groups: {}, allowed_currency_codes: ["USD"], default_currency_code: "USD",
      priority: 10, specificity: 1, regional_country_codes: [], global_fallback: false,
      ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive",
      verification_policy: "requote"
    )
    product = find_or_record(
      RecordingStudioBilling::Product, "stripe_test_monthly_plan",
      provider_account_recording: @stripe_test_provider.recording, kind: "plan",
      feature_values: { "demo_projects" => 10 }
    )
    option = find_or_record(
      RecordingStudioBilling::BillingOption, "stripe_test_monthly_plan_option",
      parent: product, product_recording: product.recording, recurrence: "recurring",
      interval: "month", interval_count: 1, quantity_mode: "fixed", default_quantity: 1,
      pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0,
      trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate",
      checkout_policy: "allowed", tax_policy: "exclusive"
    )
    price = find_or_record(
      RecordingStudioBilling::Price, "stripe_test_monthly_plan_us_price",
      parent: option, billing_option_recording: option.recording, market_recording: market.recording,
      amount_minor: 100, currency_code: "USD", currency_exponent: 2,
      pricing_model: "flat", version: 1, scope: "market"
    )
    current_price = RecordingStudioBilling::Price.with_current_recording.find_by!(key: price.key)
    return if current_price.state == "published"

    RecordingStudioBilling::CommercialPublisher.publish!(
      root_recording: @admin_root_recording,
      price_recording_ids: [current_price.recording.id],
      actor: @user
    )
  end

  def grant_stripe_workspace_access!(workspace_root)
    bootstrap_owner_access!(workspace_root)
  end

  def seed_customer_journeys!
    @override = find_or_record(
      RecordingStudioBilling::FeatureOverride, "demo_priority_support_override",
      parent: @account, root: @root_recording, account_recording: @account.recording,
      feature_recording: refresh(@priority_feature).recording, value: true, state: "draft"
    )
    hybrid = complete_checkout("seed:hybrid-checkout", [
                                 { billing_option_recording_id: @catalogue.fetch("demo_monthly_plan").fetch(:option).recording.id, quantity: 1 },
                                 { billing_option_recording_id: @catalogue.fetch("demo_quantity_addon").fetch(:option).recording.id, quantity: 2 }
                               ])
    @hybrid_subscription = project_checkout!(hybrid).subscription
    payment = RecordingStudioBilling::Payment.find_by!(financial_command: hybrid.financial_command)
    invoice = payment.invoice
    seed_usage_and_credit_pack!
    seed_checkout_presentations!
    publish_override!
    seed_money_intents!(payment, invoice)
    seed_subscription_changes!
    seed_plan_updates!
    seed_reconciliation_issue!
  end

  def seed_usage_and_credit_pack!
    usage_checkout = complete_checkout("seed:usage-checkout", [
                                         { billing_option_recording_id: @usage_option.recording.id, quantity: 1 }
                                       ])
    usage_subscription = project_checkout!(usage_checkout).subscription
    raise "dummy usage subscription missing" unless usage_subscription

    ensure_usage_credit_grant!(
      source_key: "seed:usage-allowance", grant_kind: "allowance", quantity: 5,
      effective_at: 1.hour.ago
    )
    occurred_at = Time.current
    window_starts = occurred_at.change(min: 0, sec: 0)
    window_ends = window_starts + 1.hour
    period = RecordingStudioBilling::UsagePeriod.find_or_create_by!(
      root_recording: @root_recording, account_recording: @account.recording, usage_key: "demo_api_calls",
      starts_at: window_starts, ends_at: window_ends
    ) do |usage_period|
      usage_period.state = "open"
      usage_period.safe_metadata = {}
    end
    RecordingStudioBilling::UsageAllowancePolicy.find_or_create_by!(
      usage_period: period, usage_key: "demo_api_calls", effective_at: window_starts
    ) do |policy|
      policy.root_recording = @root_recording
      policy.account_recording = @account.recording
      policy.policy_kind = "prepaid_then_overage"
      policy.limit_quantity = 5
      policy.consumed_quantity = 0
      policy.safe_metadata = { "seed" => true }
    end
    event = RecordingStudioBilling::UsageEvent.find_by(root_recording: @root_recording, idempotency_key: "seed:usage-event")
    if event && event.quantity != 11
      raise "dummy usage event quantity is #{event.quantity}, expected 11. Reset the dummy database with bin/rails db:reset from test/dummy."
    end
    unless event
      result = RecordingStudioBilling.record_usage(root_recording: @root_recording, usage_key: "demo_api_calls", quantity: 11,
                                                   idempotency_key: "seed:usage-event", occurred_at:)
      event = result.event
      raise "dummy usage event could not be recorded (#{result.status}: #{result.reason})" unless event
    end
    window_starts = event.occurred_at.change(min: 0, sec: 0)
    window_ends = window_starts + 1.hour
    @meter = refresh(@meter)
    @overage_price = refresh(@overage_price)
    usage_manifest = RecordingStudioBilling::CommercialManifest.where.not(used_at: nil).order(created_at: :desc).find do |manifest|
      manifest.canonical_data.dig("usage_rating", "meters", @meter.recording.id.to_s).present? &&
        manifest.canonical_data.fetch("overage_prices", []).any? do |price|
          price["overage_price_recording_id"] == @overage_price.recording.id
        end
    end
    raise "seeded usage manifest is missing approved metering and overage authority" unless usage_manifest

    rating_result = RecordingStudioBilling.rate_usage(root_recording: @root_recording, meter_recording: @meter.recording,
                                                      manifest_digest: usage_manifest.manifest_digest,
                                                      window_starts_at: window_starts, window_ends_at: window_ends)
    rated_usage = rating_result.rated_usage
    raise "dummy usage rating failed: #{rating_result.reason}" unless rated_usage

    allocation = RecordingStudioBilling.allocate_rated_usage(rated_usage:).allocation
    RecordingStudioBilling::CloseUsagePeriod.call(usage_period: allocation.usage_period, at: allocation.usage_period.ends_at)
    RecordingStudioBilling.calculate_overage(allocation:)

    credit_checkout = complete_checkout("seed:credit-pack-checkout", [
                                          { billing_option_recording_id: @catalogue.fetch("demo_credit_pack").fetch(:option).recording.id, quantity: 1 }
                                        ])
    credit_purchase = project_checkout!(credit_checkout).purchase
    raise "dummy credit purchase missing" unless credit_purchase

    ensure_usage_credit_grant!(
      source_key: "seed:credit-pack-grant", grant_kind: "credit", quantity: 1_000,
      effective_at: Time.current
    )
  end

  def seed_checkout_presentations!
    execute_checkout_presentation!(
      "seed:checkout-no-charge",
      [{ billing_option_recording_id: @catalogue.fetch("demo_free_plan").fetch(:option).recording.id, quantity: 1 }]
    )
    %w[redirect payment_link invoice].each do |presentation|
      execute_checkout_presentation!(
        "seed:checkout-#{presentation.tr('_', '-')}",
        [{ billing_option_recording_id: @checkout_option.recording.id, quantity: 1 }],
        presentation:
      )
    end
    monthly_option_id = @catalogue.fetch("demo_monthly_plan").fetch(:option).recording.id
    create_checkout("seed:checkout-italy", [{ billing_option_recording_id: monthly_option_id, quantity: 1 }],
                    country_code: "IT")
    create_checkout("seed:checkout-germany", [{ billing_option_recording_id: monthly_option_id, quantity: 1 }],
                    country_code: "DE")
  end

  def publish_override!
    @override = refresh(@override)
    return if @override.state == "published"

    RecordingStudioBilling::FeatureOverrideReviser.call(
      recording: @override.recording, actor: @user, attributes: { state: "published" }
    )
  end

  def seed_money_intents!(payment, invoice)
    refund_intent = RecordingStudioBilling.create_refund_intent(
      payment:, root_recording: @root_recording, local_idempotency_key: "seed:refund", amount_minor: 200,
      reason: "dummy acceptance refund", actor_reference: @user.id.to_s, tax_treatment: "provider_default",
      reversal_policy: "none", line_allocation: {}, metadata: { "seed" => true }
    ).intent
    execute_pending_command!(refund_intent.financial_command)
    RecordingStudioBilling.project_refund_intent(refund_intent:, root_recording: @root_recording) unless refund_intent.refund

    uncertain_refund = RecordingStudioBilling.create_refund_intent(
      payment:, root_recording: @root_recording, local_idempotency_key: "seed:uncertain-refund", amount_minor: 50,
      reason: "dummy uncertain refund", actor_reference: @user.id.to_s, tax_treatment: "provider_default",
      reversal_policy: "none", line_allocation: {}, metadata: { "seed" => true }
    ).intent
    execute_with_outcome(uncertain_refund, :timeout_after_possible_success)

    adjustment_intent = RecordingStudioBilling.create_adjustment_intent(
      invoice:, root_recording: @root_recording, local_idempotency_key: "seed:adjustment", kind: "credit",
      amount_minor: 100, reason: "dummy acceptance adjustment", actor_reference: @user.id.to_s,
      tax_treatment: "provider_default", affected_reference: { "invoice" => invoice.id },
      metadata: { "seed" => true }
    ).intent
    execute_pending_command!(adjustment_intent.financial_command)
    RecordingStudioBilling.project_adjustment_intent(adjustment_intent:, root_recording: @root_recording) unless adjustment_intent.financial_adjustment
  end

  def seed_subscription_changes!
    scheduled_change = RecordingStudioBilling::SubscriptionChangeIntent.find_by(subscription_recording: @hybrid_subscription.current_recording, local_idempotency_key: "seed:scheduled-change") ||
                       RecordingStudioBilling.create_subscription_change_intent(
                         subscription: @hybrid_subscription, root_recording: @root_recording,
                         local_idempotency_key: "seed:scheduled-change", change_kind: "cancellation",
                         effective_at: 1.month.from_now
                       ).intent
    applied_change = RecordingStudioBilling::SubscriptionChangeIntent.find_by(subscription_recording: @hybrid_subscription.current_recording, local_idempotency_key: "seed:applied-change") ||
                     RecordingStudioBilling.create_subscription_change_intent(
                       subscription: @hybrid_subscription, root_recording: @root_recording,
                       local_idempotency_key: "seed:applied-change", change_kind: "cancellation"
                     ).intent
    execute_pending_command!(applied_change.financial_command)
    RecordingStudioBilling.apply_subscription_change_intent(
      subscription_change_intent: applied_change, root_recording: @root_recording
    ) unless applied_change.reload.state == "applied"

    active_checkout = complete_checkout("seed:active-monthly-checkout", [
                                          { billing_option_recording_id: @catalogue.fetch("demo_monthly_plan").fetch(:option).recording.id, quantity: 1 }
                                        ])
    @active_subscription = project_checkout!(active_checkout).subscription
    failed_change = RecordingStudioBilling::SubscriptionChangeIntent.find_by(subscription_recording: @active_subscription.current_recording, local_idempotency_key: "seed:failed-change") ||
                    RecordingStudioBilling.create_subscription_change_intent(
                      subscription: @active_subscription, root_recording: @root_recording,
                      local_idempotency_key: "seed:failed-change", change_kind: "cancellation"
                    ).intent
    execute_with_outcome(failed_change, :provider_rejection)
    uncertain_change = RecordingStudioBilling::SubscriptionChangeIntent.find_by(subscription_recording: @active_subscription.current_recording, local_idempotency_key: "seed:uncertain-change") ||
                       RecordingStudioBilling.create_subscription_change_intent(
                         subscription: @active_subscription, root_recording: @root_recording,
                         local_idempotency_key: "seed:uncertain-change", change_kind: "cancellation"
                       ).intent
    execute_with_outcome(uncertain_change, :timeout_after_possible_success)
    begin
      RecordingStudioBilling.apply_subscription_change_intent(subscription_change_intent: uncertain_change, root_recording: @root_recording)
    rescue ArgumentError => error
      raise unless error.message == "subscription change provider outcome is requires_review"
    end
    @uncertain_change = uncertain_change
    scheduled_change
  end

  def seed_plan_updates!
    replacement_manifest = RecordingStudioBilling::CommercialManifest.find_by!(
      manifest_digest: @active_subscription.lines.first.manifest_digest
    )
    scheduled_update = plan_update_for("demo_plan_update_scheduled", replacement_manifest, effective_at: 1.month.from_now)
    scheduled_preview = RecordingStudioBilling.apply_plan_update(
      plan_update: scheduled_update, root_recording: @admin_root_recording, idempotency_key: "seed:plan-scheduled"
    )
    RecordingStudioBilling.apply_plan_update(
      run: scheduled_preview, root_recording: @admin_root_recording, idempotency_key: "seed:plan-scheduled",
      confirmation: { "approved_by" => @user.id.to_s }
    )
    apply_plan_run("demo_plan_update_applied", "seed:plan-applied", replacement_manifest, :success)
    apply_plan_run("demo_plan_update_failed", "seed:plan-failed", replacement_manifest, :provider_rejection)
    apply_plan_run("demo_plan_update_uncertain", "seed:plan-uncertain", replacement_manifest, :timeout_after_possible_success)
  end

  def plan_update_for(key, replacement_manifest, effective_at: nil)
    update = RecordingStudioBilling::PlanUpdate.with_current_recording.find_by(key:) ||
             record_child(
               RecordingStudioBilling::PlanUpdate.new(
                 billing_option_recording: @catalogue.fetch("demo_monthly_plan").fetch(:option).recording,
                 key:, allowance_policy: "preserve", execution_state: "draft",
                 replacement_manifest_digest: replacement_manifest.manifest_digest,
                 replacement_configuration: {
                   "audience" => { "root_recording_ids" => [@root_recording.id] },
                   "effective_at" => effective_at&.iso8601
                 }
               ), @admin_root_recording, @billing_admin.recording
             )
    refresh(update)
  end

  def apply_plan_run(update_key, idempotency_key, replacement_manifest, outcome)
    update = plan_update_for(update_key, replacement_manifest)
    preview = RecordingStudioBilling.apply_plan_update(plan_update: update, root_recording: @admin_root_recording, idempotency_key:)
    run = RecordingStudioBilling.apply_plan_update(
      run: preview, root_recording: @admin_root_recording, idempotency_key:,
      confirmation: { "approved_by" => @user.id.to_s }
    )
    run.applications.each { |application| execute_with_outcome(application.subscription_change_intent, outcome) }
    RecordingStudioBilling.apply_plan_update(run:, root_recording: @admin_root_recording, idempotency_key:)
  end

  def seed_reconciliation_issue!
    command = @uncertain_change.financial_command
    RecordingStudioBilling::ReconciliationIssue.find_or_create_by!(
      financial_command: command, authority: "provider", kind: "provider_result_mismatch"
    ) do |issue|
      issue.provider_account_recording_id = @fake_provider.recording.id
      issue.provider_adapter_key = "fake"
      issue.state = "open"
      issue.safe_payload = { "seed" => true, "local_idempotency_key" => "seed:uncertain-change" }
    end
  end

  def register_tax_calculators!
    registry = RecordingStudioBilling.configuration.tax_calculator_registry
    unless registry.keys.include?("dummy_exclusive")
      RecordingStudioBilling.register_tax_calculator(
        :dummy_exclusive, RecordingStudioBilling::FakeTaxCalculator.new(outcome: :exclusive)
      )
    end
    return if registry.keys.include?("dummy_inclusive")

    RecordingStudioBilling.register_tax_calculator(
      :dummy_inclusive, RecordingStudioBilling::FakeTaxCalculator.new(outcome: :inclusive)
    )
  end

  def complete_checkout(key, items, presentation: nil, country_code: "US", project_payment: true)
    intent = create_checkout(key, items, presentation:, country_code:)
    if intent.state == "pending_provider" && intent.financial_command.state == "pending"
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: @root_recording)
    end
    command = intent.financial_command
    RecordingStudioBilling.reconcile_provider_command(command:) unless command.reload.normalized_result.key?("payment_state")
    if project_payment && !RecordingStudioBilling::Payment.exists?(financial_command: command)
      RecordingStudioBilling.project_checkout_financial_records(checkout_intent: intent, root_recording: @root_recording)
    end
    intent.reload
  end

  def execute_checkout_presentation!(key, items, presentation: nil, country_code: "US")
    intent = create_checkout(key, items, presentation:, country_code:)
    return intent unless intent.state == "pending_provider" && intent.financial_command.state == "pending"

    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: @root_recording)
    intent.reload
  end

  def create_checkout(key, items, presentation: nil, country_code: "US")
    existing = RecordingStudioBilling::CheckoutIntent.find_by(root_recording: @root_recording, local_idempotency_key: key)
    return existing if existing

    RecordingStudioBilling.create_checkout_intent(
      root_recording: @root_recording, local_idempotency_key: key, country_code:,
      items:, presentation:
    ).intent
  end

  def project_checkout!(intent)
    RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: intent, root_recording: @root_recording)
  rescue ArgumentError => error
    raise unless error.message == "unsupported commercial lifecycle mode"

    raise "dummy lifecycle mode rejected #{intent.local_idempotency_key}: #{intent.items.map { |item| item.commercial_manifest.fetch('canonical_data').slice('product', 'billing_option', 'price') }}"
  end

  def execute_pending_command!(command)
    return unless command.state == "pending"

    RecordingStudioBilling::FinancialCommandExecutor.execute(command:, provider_key: "fake")
  end

  def execute_with_outcome(intent, outcome)
    return unless intent.financial_command.state == "pending"

    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider(:fake, RecordingStudioBilling::FakeFinancialAdapter.new(outcome:))
    RecordingStudioBilling::FinancialCommandExecutor.execute(command: intent.financial_command, provider_key: "fake")
  rescue RecordingStudioBilling::FakeFinancialAdapter::TimeoutAfterPossibleSuccess
  ensure
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_builtin_providers!
    RecordingStudioBilling.register_provider(:fake, RecordingStudioBilling::DummyFinancialAdapter.new)
  end

  def ensure_usage_credit_grant!(source_key:, grant_kind:, quantity:, effective_at:)
    RecordingStudioBilling::UsageCreditGrant.find_or_create_by!(root_recording: @root_recording, source_key:) do |grant|
      grant.account_recording = @account.recording
      grant.credit_key = "demo_api_calls"
      grant.grant_kind = grant_kind
      grant.quantity = quantity
      grant.remaining_quantity = quantity
      grant.effective_at = effective_at
      grant.safe_metadata = { "seed" => true }
    end
  end

  def find_or_record(model, key, parent: nil, root: nil, unique_by: nil, **attributes)
    scope = model.with_current_recording
    record = if unique_by == :product
               scope.find_by(key:, product_recording_id: attributes.fetch(:product_recording).id)
             else
               scope.find_by(key:)
             end
    return remember!(record) if record

    parent_recording = recording_for(parent) || @billing_admin.recording
    record_child(model.new(attributes.merge(key:)), root || @admin_root_recording, parent_recording)
  end

  def record_child(recordable, root, parent)
    recording = root.record(recordable, parent_recording: parent)
    remember!(RecordingStudio::Recording.unscoped.find(recording.id).recordable)
  end

  def refresh(record)
    remember!(RecordingStudio::Recording.unscoped.find(recording_id_for(record)).recordable)
  end

  def remember!(record)
    recording = record.recording
    recording_ids[record] = recording.id if recording
    record
  end

  def recording_for(record)
    return if record.nil?

    record.recording || RecordingStudio::Recording.unscoped.find(recording_id_for(record))
  end

  def recording_id_for(record)
    record.recording&.id || recording_ids.fetch(record)
  end

  def recording_ids
    @recording_ids ||= {}
  end

  def assert_record!(record, **expected)
    expected.each do |attribute, value|
      actual = record.public_send(attribute)
      next if actual == value

      raise "dummy catalogue #{record.class.name} #{record.key} has #{attribute}=#{actual.inspect}, expected #{value.inspect}. Reset the dummy database with bin/rails db:reset from test/dummy."
    end
    record
  end
end
