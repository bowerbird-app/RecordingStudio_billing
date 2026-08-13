# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# Create the admin user
user = User.find_or_create_by!(email: "admin@admin.com") do |u|
  u.password = "Password"
  u.password_confirmation = "Password"
end

# Create the billing roots and their capability-owned child recordables.
workspace = Workspace.find_or_create_by!(name: "Studio Workspace")
admin_root = AdminRoot.find_or_create_by!(name: "Billing Administration")
previous_actor = Current.actor
Current.actor = user

begin
  # Create the root recording
  root_recording = RecordingStudio.root_recording_for(workspace)
  admin_root_recording = RecordingStudio.root_recording_for(admin_root)

  account = RecordingStudioBilling.ensure_account(root_recording: root_recording, name: "Studio Account")
  billing_admin = RecordingStudioBilling.ensure_billing_admin(
    root_recording: admin_root_recording,
    key: "billing"
  )
ensure
  Current.actor = previous_actor
end

record_child = lambda do |recordable, root, parent|
  recording = root.record(recordable, parent_recording: parent)
  RecordingStudio::Recording.unscoped.find(recording.id).recordable
end

previous_actor = Current.actor
Current.actor = user

begin
  fake_provider = RecordingStudioBilling::ProviderAccount.with_current_recording.find_by(key: "demo_fake_provider") ||
                  record_child.call(
                    RecordingStudioBilling::ProviderAccount.new(
                      billing_admin_recording: billing_admin.recording, key: "demo_fake_provider", adapter_key: "fake",
                      name: "Demo fake provider", environment: "test", configuration: {}, capabilities: [],
                      supported_markets: %w[US GB IT DE], supported_currencies: %w[USD GBP EUR]
                    ), admin_root_recording, billing_admin.recording
                  )
  stripe_test_provider = RecordingStudioBilling::ProviderAccount.with_current_recording.find_by(key: "demo_stripe_test_provider") ||
                         record_child.call(
                           RecordingStudioBilling::ProviderAccount.new(
                             billing_admin_recording: billing_admin.recording, key: "demo_stripe_test_provider", adapter_key: "stripe",
                             name: "Demo Stripe test provider", environment: "test", configuration: { "display_name" => "Stripe test" }, capabilities: [],
                             supported_markets: %w[US GB IT DE], supported_currencies: %w[USD GBP EUR]
                           ), admin_root_recording, billing_admin.recording
                         )
  product = RecordingStudioBilling::Product.with_current_recording.find_by(key: "demo_checkout_product") ||
            record_child.call(
              RecordingStudioBilling::Product.new(
                provider_account_recording: fake_provider.recording, key: "demo_checkout_product", kind: "service", feature_values: {}
              ), admin_root_recording, billing_admin.recording
            )
  option = RecordingStudioBilling::BillingOption.with_current_recording.find_by(key: "demo_checkout_option") ||
           record_child.call(
             RecordingStudioBilling::BillingOption.new(
               product_recording: product.recording, key: "demo_checkout_option", recurrence: "one_time", quantity_mode: "fixed",
               default_quantity: 1, pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0,
               trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"
             ), admin_root_recording, product.recording
           )

  market_specs = {
    "demo_us_market" => { countries: ["US"], currency: "USD", amount: 1_200, global: false },
    "demo_uk_market" => { countries: ["GB"], currency: "GBP", amount: 900, global: false },
    "demo_it_market" => { countries: ["IT"], currency: "EUR", amount: 1_000, global: false },
    "demo_de_market" => { countries: ["DE"], currency: "EUR", amount: 1_100, global: false },
    "demo_global_market" => { countries: [], currency: "USD", amount: 1_300, global: true }
  }
  prices = market_specs.map do |market_key, spec|
    market = RecordingStudioBilling::Market.with_current_recording.find_by(key: market_key) ||
             record_child.call(
               RecordingStudioBilling::Market.new(
                 provider_account_recording: fake_provider.recording, key: market_key, country_codes: spec[:countries], country_groups: {},
                 allowed_currency_codes: [spec[:currency]], default_currency_code: spec[:currency], priority: 10, specificity: 1,
                 regional_country_codes: [], global_fallback: spec[:global], ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive",
                 verification_policy: "requote"
               ), admin_root_recording, billing_admin.recording
             )
    price_key = "#{market_key}_price"
    RecordingStudioBilling::Price.with_current_recording.find_by(key: price_key) ||
      record_child.call(
        RecordingStudioBilling::Price.new(
          billing_option_recording: option.recording, market_recording: market.recording, key: price_key,
          amount_minor: spec[:amount], currency_code: spec[:currency], currency_exponent: 2, pricing_model: "flat", version: 1, scope: "default"
        ), admin_root_recording, option.recording
      )
  end

  usage_product = RecordingStudioBilling::Product.with_current_recording.find_by(key: "demo_usage_product") ||
                  record_child.call(
                    RecordingStudioBilling::Product.new(
                      provider_account_recording: fake_provider.recording, key: "demo_usage_product", kind: "service", feature_values: {}
                    ), admin_root_recording, billing_admin.recording
                  )
  usage_option = RecordingStudioBilling::BillingOption.with_current_recording.find_by(key: "demo_usage_option") ||
                 record_child.call(
                   RecordingStudioBilling::BillingOption.new(
                     product_recording: usage_product.recording, key: "demo_usage_option", recurrence: "one_time", quantity_mode: "fixed",
                     default_quantity: 1, pricing_model: "per_unit", collection_method: "automatic", payment_terms_days: 0,
                     trial_days: 0, proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"
                   ), admin_root_recording, usage_product.recording
                 )
  usage_unit = RecordingStudioBilling::UsageUnit.with_current_recording.find_by(key: "demo_api_call") ||
               record_child.call(
                 RecordingStudioBilling::UsageUnit.new(provider_account_recording: fake_provider.recording, key: "demo_api_call"),
                 admin_root_recording, billing_admin.recording
               )
  meter = RecordingStudioBilling::Meter.with_current_recording.find_by(key: "demo_api_calls") ||
          record_child.call(
            RecordingStudioBilling::Meter.new(usage_unit_recording: usage_unit.recording, key: "demo_api_calls", aggregation: "sum"),
            admin_root_recording, billing_admin.recording
          )
  rate_card = RecordingStudioBilling::RateCard.with_current_recording.find_by(key: "demo_usage_rates") ||
              record_child.call(
                RecordingStudioBilling::RateCard.new(provider_account_recording: fake_provider.recording, key: "demo_usage_rates"),
                admin_root_recording, billing_admin.recording
              )
  rate = RecordingStudioBilling::Rate.with_current_recording.find_by(key: "demo_api_call_conversion") ||
         record_child.call(
           RecordingStudioBilling::Rate.new(
             rate_card_recording: rate_card.recording, usage_unit_recording: usage_unit.recording, key: "demo_api_call_conversion",
             conversion_numerator: 1, conversion_denominator: 1
           ), admin_root_recording, rate_card.recording
         )
  cost_card = RecordingStudioBilling::CostCard.with_current_recording.find_by(key: "demo_usage_costs") ||
              record_child.call(
                RecordingStudioBilling::CostCard.new(provider_account_recording: fake_provider.recording, key: "demo_usage_costs"),
                admin_root_recording, billing_admin.recording
              )
  cost_rate = RecordingStudioBilling::CostRate.with_current_recording.find_by(key: "demo_api_call_cost") ||
              record_child.call(
                RecordingStudioBilling::CostRate.new(
                  cost_card_recording: cost_card.recording, usage_unit_recording: usage_unit.recording, key: "demo_api_call_cost",
                  amount_minor: 2, currency_code: "USD", currency_exponent: 2
                ), admin_root_recording, cost_card.recording
              )
  usage_market = RecordingStudioBilling::Market.with_current_recording.find_by!(key: "demo_us_market")
  usage_price = RecordingStudioBilling::Price.with_current_recording.find_by(key: "demo_usage_us_price") ||
                record_child.call(
                  RecordingStudioBilling::Price.new(
                    billing_option_recording: usage_option.recording, market_recording: usage_market.recording, key: "demo_usage_us_price",
                    amount_minor: 100, currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "default"
                  ), admin_root_recording, usage_option.recording
                )
  overage_price = RecordingStudioBilling::OveragePrice.with_current_recording.find_by(key: "demo_usage_api_overage") ||
                  record_child.call(
                    RecordingStudioBilling::OveragePrice.new(
                      billing_option_recording: usage_option.recording, market_recording: usage_market.recording,
                      usage_unit_recording: usage_unit.recording, key: "demo_usage_api_overage", amount_minor: 5,
                      currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "default"
                    ), admin_root_recording, usage_option.recording
                  )
  plan_specs = {
    "demo_free_plan" => { amount: 0, recurrence: "recurring", interval: "month", kind: "plan" },
    "demo_monthly_plan" => { amount: 4_900, recurrence: "recurring", interval: "month", kind: "plan" },
    "demo_annual_plan" => { amount: 49_000, recurrence: "recurring", interval: "year", kind: "plan" },
    "demo_quantity_addon" => { amount: 1_000, recurrence: "recurring", interval: "month", kind: "addon" },
    "demo_credit_pack" => { amount: 2_500, recurrence: "one_time", interval: nil, kind: "credit_pack" }
  }
  catalogue_prices = plan_specs.map do |key, spec|
    product = RecordingStudioBilling::Product.with_current_recording.find_by(key:) ||
              record_child.call(
                RecordingStudioBilling::Product.new(provider_account_recording: fake_provider.recording, key:, kind: spec[:kind], feature_values: {}),
                admin_root_recording, billing_admin.recording
              )
    option = RecordingStudioBilling::BillingOption.with_current_recording.find_by(key: "#{key}_option") ||
             record_child.call(
               RecordingStudioBilling::BillingOption.new(
                 product_recording: product.recording, key: "#{key}_option", recurrence: spec[:recurrence], interval: spec[:interval],
                 interval_count: spec[:interval] ? 1 : nil, quantity_mode: key == "demo_quantity_addon" ? "adjustable" : "fixed",
                 minimum_quantity: key == "demo_quantity_addon" ? 1 : nil, maximum_quantity: key == "demo_quantity_addon" ? 25 : nil,
                 default_quantity: 1, pricing_model: "flat", collection_method: "automatic", payment_terms_days: 0, trial_days: 0,
                 proration_policy: "none", lifecycle_policy: "immediate", checkout_policy: "allowed", tax_policy: "exclusive"
               ), admin_root_recording, product.recording
             )
    RecordingStudioBilling::Price.with_current_recording.find_by(key: "#{key}_us_price") ||
      record_child.call(
        RecordingStudioBilling::Price.new(billing_option_recording: option.recording, market_recording: usage_market.recording,
                                          key: "#{key}_us_price", amount_minor: spec[:amount], currency_code: "USD", currency_exponent: 2,
                                          pricing_model: "flat", version: 1, scope: "default"), admin_root_recording, option.recording
      )
  end
  RecordingStudioBilling::ProductRule.with_current_recording.find_by(key: "demo_addon_requires_plan") ||
    record_child.call(
      RecordingStudioBilling::ProductRule.new(product_recording: RecordingStudioBilling::Product.with_current_recording.find_by!(key: "demo_quantity_addon").recording,
                                               target_product_recording: RecordingStudioBilling::Product.with_current_recording.find_by!(key: "demo_monthly_plan").recording,
                                               key: "demo_addon_requires_plan", rule_type: "requires", conditions: { "country_code" => "US" }),
      admin_root_recording, billing_admin.recording
    )
  monthly_option = RecordingStudioBilling::BillingOption.with_current_recording.find_by!(key: "demo_monthly_plan_option")
  RecordingStudioBilling::PlanUpdate.with_current_recording.find_by(key: "demo_monthly_plan_review") ||
    record_child.call(
      RecordingStudioBilling::PlanUpdate.new(billing_option_recording: monthly_option.recording, key: "demo_monthly_plan_review"),
      admin_root_recording, billing_admin.recording
    )
  unpublished_price_ids = (prices + [usage_price] + catalogue_prices).reject { |price| price.state == "published" }.map { |price| price.recording.id }
  RecordingStudioBilling::CommercialPublisher.publish!(root_recording: admin_root_recording, price_recording_ids: unpublished_price_ids, actor: user) if unpublished_price_ids.any?

  seed_command = lambda do |key, command_type|
    RecordingStudioBilling::FinancialCommand.find_by(local_idempotency_key: "seed:#{key}") ||
      RecordingStudioBilling.create_financial_command(
        root_recording:, account_recording: account.recording, command_type:, local_idempotency_key: "seed:#{key}",
        provider_account_recording: fake_provider.recording, provider_adapter_key: "fake", request: { seed_key: key }
      ).command
  end
  charge_command = seed_command.call("charge", "checkout")
  invoice = RecordingStudioBilling::Invoice.find_or_create_by!(provider_reference: "demo_invoice_001") do |record|
    record.root_recording = root_recording
    record.account_recording = account.recording
    record.financial_command = charge_command
    record.currency_code = "USD"
    record.total_minor = 1_200
    record.state = "paid"
    record.issued_at = Time.current
    record.safe_snapshot = { "demo" => "invoice" }
  end
  payment = RecordingStudioBilling::Payment.find_or_create_by!(financial_command: charge_command) do |record|
    record.root_recording = root_recording
    record.account_recording = account.recording
    record.invoice = invoice
    record.provider_reference = "demo_payment_001"
    record.currency_code = "USD"
    record.amount_minor = 1_200
    record.state = "paid"
    record.recorded_at = Time.current
    record.safe_snapshot = { "demo" => "payment" }
  end
  refund_intent = RecordingStudioBilling::RefundIntent.find_or_create_by!(local_idempotency_key: "seed:refund") do |record|
    record.payment = payment
    record.root_recording = root_recording
    record.account_recording = account.recording
    record.request_fingerprint = Digest::SHA256.hexdigest("demo refund")
    record.amount_minor = 200
    record.currency_code = "USD"
    record.state = "completed"
    record.safe_metadata = { "demo" => "refund" }
    record.tax_treatment = "provider_default"
    record.reversal_policy = "none"
    record.line_allocation = {}
  end
  refund_command = seed_command.call("refund", "refund")
  refund_intent.update!(financial_command: refund_command) unless refund_intent.financial_command_id?
  RecordingStudioBilling::Refund.find_or_create_by!(refund_intent:) do |record|
    record.payment = payment
    record.financial_command = refund_command
    record.amount_minor = refund_intent.amount_minor
    record.currency_code = "USD"
    record.provider_reference = "demo_refund_001"
    record.recorded_at = Time.current
    record.safe_snapshot = { "demo" => "refund" }
  end
  adjustment_intent = RecordingStudioBilling::AdjustmentIntent.find_or_create_by!(local_idempotency_key: "seed:adjustment") do |record|
    record.invoice = invoice
    record.root_recording = root_recording
    record.account_recording = account.recording
    record.request_fingerprint = Digest::SHA256.hexdigest("demo adjustment")
    record.kind = "credit"
    record.amount_minor = 100
    record.currency_code = "USD"
    record.state = "completed"
    record.safe_metadata = { "demo" => "adjustment" }
    record.tax_treatment = "provider_default"
    record.approved_authority = {}
    record.affected_reference = {}
  end
  adjustment_command = seed_command.call("adjustment", "adjustment")
  adjustment_intent.update!(financial_command: adjustment_command) unless adjustment_intent.financial_command_id?
  RecordingStudioBilling::FinancialAdjustment.find_or_create_by!(adjustment_intent:) do |record|
    record.invoice = invoice
    record.financial_command = adjustment_command
    record.kind = "credit"
    record.amount_minor = adjustment_intent.amount_minor
    record.currency_code = "USD"
    record.recorded_at = Time.current
    record.safe_snapshot = { "demo" => "adjustment" }
  end
  RecordingStudioBilling::ReconciliationIssue.find_or_create_by!(financial_command: charge_command, kind: "demo_provider_terms") do |record|
    record.authority = "demo_seed"
    record.state = "open"
    record.safe_payload = { "demo" => "reconciliation" }
  end
  %w[disabled unsupported pending].each do |tax_state|
    RecordingStudioBilling::ReconciliationIssue.find_or_create_by!(financial_command: nil, kind: "demo_tax_#{tax_state}") do |record|
      record.authority = "tax"
      record.state = "open"
      record.safe_payload = { "tax_state" => tax_state, "demo" => true }
    end
  end
  closed_period = RecordingStudioBilling::UsagePeriod.find_or_create_by!(root_recording:, account_recording: account.recording,
                                                                           usage_key: "demo_api_calls", starts_at: 1.month.ago.beginning_of_month,
                                                                           ends_at: 1.month.ago.end_of_month) do |record|
    record.state = "closed"
    record.closed_at = Time.current
    record.safe_metadata = { "demo" => "closed_usage_period", "overage_price_key" => overage_price.key }
  end
  RecordingStudioBilling::UsageCreditGrant.find_or_create_by!(root_recording:, source_key: "demo_usage_credit") do |record|
    record.account_recording = account.recording
    record.credit_key = "demo_api_calls"
    record.grant_kind = "credit"
    record.quantity = 100
    record.remaining_quantity = 40
    record.effective_at = closed_period.starts_at
    record.source_key = "demo_usage_credit"
    record.safe_metadata = { "demo" => "closed_period_credit", "usage_period_id" => closed_period.id }
  end
ensure
  Current.actor = previous_actor
end

puts "Seeded: admin@admin.com / Password"
puts "Seeded: Workspace '#{workspace.name}' with root recording ##{root_recording.id}"
puts "Seeded: Admin root '#{admin_root.name}' with root recording ##{admin_root_recording.id}"
puts "Seeded: Billing account '#{account.name}' and billing admin '#{billing_admin.key}'"
puts "Seeded: Fake provider '#{fake_provider.key}' with no credentials or network calls"
puts "Seeded: Stripe test provider '#{stripe_test_provider.key}' with no credentials or network calls"
puts "Seeded: published checkout pricing for US, UK, IT, DE, and global markets"
puts "Seeded: published metered API-call catalogue with rates, costs, and US overage pricing"
puts "Seeded: free, monthly, annual, quantity-addon, and credit-pack catalogue examples"
puts "Seeded: published plan-update review example"
puts "Seeded: invoice, payment, refund, adjustment, reconciliation, and tax-state examples"
puts "Seeded: closed API-call usage period with credit balance and published overage pricing"
