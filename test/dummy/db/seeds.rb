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
  root_recording = RecordingStudio::Recording.unscoped.find(root_recording.id)
  admin_root_recording = RecordingStudio::Recording.unscoped.find(admin_root_recording.id)
  account_recording = RecordingStudio::Recording.unscoped.find_by!(
    root_recording: root_recording, parent_recording: root_recording,
    recordable_type: "RecordingStudioBilling::Account", trashed_at: nil
  )
  billing_admin_recording = RecordingStudio::Recording.unscoped.find_by!(
    root_recording: admin_root_recording, parent_recording: admin_root_recording,
    recordable_type: "RecordingStudioBilling::BillingAdmin", trashed_at: nil
  )
  account = account_recording.recordable
  billing_admin = billing_admin_recording.recordable
ensure
  Current.actor = previous_actor
end

record_child = lambda do |recordable, root, parent|
  recording = root.record(recordable, parent_recording: parent)
  RecordingStudio::Recording.unscoped.find(recording.id).recordable
end
refresh_recordable = lambda do |recording_id|
  RecordingStudio::Recording.unscoped.find(recording_id).recordable
end
catalogue_recordable = lambda do |recordable_type, key|
  RecordingStudio::Recording.unscoped.where(root_recording: admin_root_recording, recordable_type:, trashed_at: nil).find do |recording|
    recording.recordable.key == key
  end&.recordable
end

previous_actor = Current.actor
Current.actor = user

begin
  RecordingStudioBilling.register_builtin_providers!
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
  checkout_product_recording_id = product.recording.id
  checkout_option_recording_id = option.recording.id

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
          amount_minor: spec[:amount], currency_code: spec[:currency], currency_exponent: 2, pricing_model: "flat", version: 1, scope: "market"
        ), admin_root_recording, option.recording
      )
  end
  market_recording_ids = prices.to_h { |price| [price.key.delete_suffix("_price"), price.market_recording_id] }

  usage_product = RecordingStudioBilling::Product.with_current_recording.find_by(key: "demo_usage_product") ||
                  record_child.call(
                    RecordingStudioBilling::Product.new(
                      provider_account_recording: fake_provider.recording, key: "demo_usage_product", kind: "credit_pack", feature_values: {}
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
                    amount_minor: 100, currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "market"
                  ), admin_root_recording, usage_option.recording
                )
  overage_price = RecordingStudioBilling::OveragePrice.with_current_recording.find_by(key: "demo_usage_api_overage") ||
                  record_child.call(
                    RecordingStudioBilling::OveragePrice.new(
                      billing_option_recording: usage_option.recording, market_recording: usage_market.recording,
                      usage_unit_recording: usage_unit.recording, key: "demo_usage_api_overage", amount_minor: 5,
                      currency_code: "USD", currency_exponent: 2, pricing_model: "per_unit", version: 1, scope: "market"
                    ), admin_root_recording, usage_option.recording
                  )
  usage_recording_ids = {
    product: usage_product.recording.id, option: usage_option.recording.id, unit: usage_unit.recording.id,
    meter: meter.recording.id, rate_card: rate_card.recording.id, rate: rate.recording.id,
    cost_card: cost_card.recording.id, cost_rate: cost_rate.recording.id, market: usage_market.recording.id,
    price: usage_price.recording.id, overage_price: overage_price.recording.id
  }
  plan_specs = {
    "demo_free_plan" => { amount: 0, recurrence: "recurring", interval: "month", kind: "plan" },
    "demo_monthly_plan" => { amount: 4_900, recurrence: "recurring", interval: "month", kind: "plan" },
    "demo_annual_plan" => { amount: 49_000, recurrence: "recurring", interval: "year", kind: "plan" },
    "demo_quantity_addon" => { amount: 1_000, recurrence: "recurring", interval: "month", kind: "addon" },
    "demo_credit_pack" => { amount: 2_500, recurrence: "one_time", interval: nil, kind: "credit_pack" }
  }
  catalogue = plan_specs.to_h do |key, spec|
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
    price = RecordingStudioBilling::Price.with_current_recording.find_by(key: "#{key}_us_price") ||
            record_child.call(
        RecordingStudioBilling::Price.new(billing_option_recording: option.recording, market_recording: usage_market.recording,
                                          key: "#{key}_us_price", amount_minor: spec[:amount], currency_code: "USD", currency_exponent: 2,
                                          pricing_model: "flat", version: 1, scope: "market"), admin_root_recording, option.recording
      )
    [key, { product_recording_id: product.recording.id, option_recording_id: option.recording.id, price_recording_id: price.recording.id }]
  end
  catalogue_prices = catalogue.values.map { |entry| refresh_recordable.call(entry.fetch(:price_recording_id)) }
  RecordingStudioBilling::ProductRule.with_current_recording.find_by(key: "demo_addon_requires_plan") ||
    record_child.call(
      RecordingStudioBilling::ProductRule.new(product_recording_id: catalogue.fetch("demo_quantity_addon").fetch(:product_recording_id),
                       target_product_recording_id: catalogue.fetch("demo_monthly_plan").fetch(:product_recording_id),
                                               key: "demo_addon_requires_plan", rule_type: "requires", conditions: { "country_code" => "US" }),
      admin_root_recording, billing_admin.recording
    )
  monthly_option = refresh_recordable.call(catalogue.fetch("demo_monthly_plan").fetch(:option_recording_id))
  monthly_plan_update = RecordingStudioBilling::PlanUpdate.with_current_recording.find_by(key: "demo_monthly_plan_review") ||
                        record_child.call(
      RecordingStudioBilling::PlanUpdate.new(billing_option_recording: monthly_option.recording, key: "demo_monthly_plan_review"),
      admin_root_recording, billing_admin.recording
    )
  monthly_plan_update_recording_id = monthly_plan_update.recording.id
  unpublished_price_ids = (prices + [usage_price] + catalogue_prices).reject { |price| price.state == "published" }.map { |price| price.recording.id }
  RecordingStudioBilling::CommercialPublisher.publish!(root_recording: admin_root_recording, price_recording_ids: unpublished_price_ids, actor: user) if unpublished_price_ids.any?

  fake_provider = refresh_recordable.call(fake_provider.recording.id)
  stripe_test_provider = refresh_recordable.call(stripe_test_provider.recording.id)
  monthly_product = refresh_recordable.call(catalogue.fetch("demo_monthly_plan").fetch(:product_recording_id))
  monthly_option = refresh_recordable.call(catalogue.fetch("demo_monthly_plan").fetch(:option_recording_id))
  monthly_price = refresh_recordable.call(catalogue.fetch("demo_monthly_plan").fetch(:price_recording_id))
  addon_product = refresh_recordable.call(catalogue.fetch("demo_quantity_addon").fetch(:product_recording_id))
  addon_option = refresh_recordable.call(catalogue.fetch("demo_quantity_addon").fetch(:option_recording_id))
  usage_product = refresh_recordable.call(usage_recording_ids.fetch(:product))
  usage_option = refresh_recordable.call(usage_recording_ids.fetch(:option))
  usage_unit = refresh_recordable.call(usage_recording_ids.fetch(:unit))
  meter = refresh_recordable.call(usage_recording_ids.fetch(:meter))
  usage_market = refresh_recordable.call(usage_recording_ids.fetch(:market))
  usage_price = refresh_recordable.call(usage_recording_ids.fetch(:price))
  overage_price = refresh_recordable.call(usage_recording_ids.fetch(:overage_price))
  monthly_plan_update = refresh_recordable.call(monthly_plan_update_recording_id)
  feature = catalogue_recordable.call("RecordingStudioBilling::Feature", "demo_priority_support") ||
            record_child.call(
              RecordingStudioBilling::Feature.new(product_recording: monthly_product.recording, key: "demo_priority_support",
                                                   kind: "boolean", definition: {}),
              admin_root_recording, monthly_product.recording
            )
  unless catalogue_recordable.call("RecordingStudioBilling::Feature", "demo_priority_support")&.product_recording_id == addon_product.recording.id
    record_child.call(
      RecordingStudioBilling::Feature.new(product_recording: addon_product.recording, key: "demo_priority_support",
                                           kind: "boolean", definition: {}),
      admin_root_recording, addon_product.recording
    )
  end
  feature_recording_id = feature.recording.id
  unless feature.state == "published"
    RecordingStudioBilling::CommercialPublisher.publish!(root_recording: admin_root_recording,
                                                          price_recording_ids: [monthly_price.recording.id], actor: user)
  end
  feature = refresh_recordable.call(feature_recording_id)
  override = RecordingStudioBilling::FeatureOverride.with_current_recording.find_by(key: "demo_priority_support_override") ||
             record_child.call(
               RecordingStudioBilling::FeatureOverride.new(account_recording: account.recording, feature_recording: feature.recording,
                                                           key: "demo_priority_support_override", value: true, state: "draft"),
               root_recording, account.recording
             )

  stripe_configuration_probe = RecordingStudioBilling::FinancialCommand.find_by(root_recording:, local_idempotency_key: "seed:stripe-configuration-probe")
  if stripe_configuration_probe.nil? && RecordingStudioBilling.configuration.stripe_credential_resolver.nil?
    stripe_configuration_probe = RecordingStudioBilling.execute_financial_command(
      root_recording:, account_recording: account.recording,
      command_type: "provider_configuration_check", local_idempotency_key: "seed:stripe-configuration-probe",
      provider_account_recording: stripe_test_provider.recording, provider_key: "stripe",
      request: { "purpose" => "dummy_stripe_configuration_probe" }
    ).command
  end

  hybrid_checkout = RecordingStudioBilling::CheckoutIntent.find_by(root_recording:, local_idempotency_key: "seed:hybrid-checkout") ||
                    RecordingStudioBilling.create_checkout_intent(
                      root_recording:, local_idempotency_key: "seed:hybrid-checkout", country_code: "US",
                      items: [{ billing_option_recording_id: monthly_option.recording.id, quantity: 1 },
                              { billing_option_recording_id: addon_option.recording.id, quantity: 2 }]
                    ).intent
  if hybrid_checkout.state == "pending_provider" && hybrid_checkout.financial_command.state == "pending"
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: hybrid_checkout, root_recording:)
  end
  checkout_command = hybrid_checkout.financial_command
  RecordingStudioBilling.reconcile_provider_command(command: checkout_command) unless checkout_command.reload.normalized_result.key?("payment_state")
  RecordingStudioBilling.project_checkout_financial_records(checkout_intent: hybrid_checkout, root_recording:) unless RecordingStudioBilling::Payment.exists?(financial_command: checkout_command)
  begin
    hybrid_subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: hybrid_checkout, root_recording:).subscription
  rescue ArgumentError => error
    raise unless error.message == "unsupported commercial lifecycle mode"

    raise "dummy lifecycle mode rejected #{hybrid_checkout.local_idempotency_key}: #{hybrid_checkout.items.map { |item| item.commercial_manifest.fetch('canonical_data').slice('product', 'billing_option', 'price') }}"
  end
  payment = RecordingStudioBilling::Payment.find_by!(financial_command: checkout_command)
  invoice = payment.invoice

  unless catalogue_recordable.call("RecordingStudioBilling::Feature", "demo_api_calls")
    record_child.call(
      RecordingStudioBilling::Feature.new(product_recording: usage_product.recording, key: "demo_api_calls",
                                           kind: "boolean", definition: {}),
      admin_root_recording, usage_product.recording
    )
  end
  usage_feature = catalogue_recordable.call("RecordingStudioBilling::Feature", "demo_api_calls")
  raise "seeded usage feature is missing" unless usage_feature&.product_recording_id == usage_product.recording.id
  usage_feature_recording_id = usage_feature.recording.id
  RecordingStudioBilling::CommercialPublisher.publish!(root_recording: admin_root_recording,
                                                        price_recording_ids: [usage_price.recording.id], actor: user) unless usage_feature.state == "published"
  usage_checkout = RecordingStudioBilling::CheckoutIntent.find_by(root_recording:, local_idempotency_key: "seed:usage-checkout") ||
                   RecordingStudioBilling.create_checkout_intent(
                     root_recording:, local_idempotency_key: "seed:usage-checkout", country_code: "US",
                     items: [{ billing_option_recording_id: usage_option.recording.id, quantity: 1 }]
                   ).intent
  if usage_checkout.state == "pending_provider" && usage_checkout.financial_command.state == "pending"
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: usage_checkout, root_recording:)
  end
  usage_command = usage_checkout.financial_command
  RecordingStudioBilling.reconcile_provider_command(command: usage_command) unless usage_command.reload.normalized_result.key?("payment_state")
  RecordingStudioBilling.project_checkout_financial_records(checkout_intent: usage_checkout, root_recording:) unless RecordingStudioBilling::Payment.exists?(financial_command: usage_command)
  begin
    usage_purchase = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: usage_checkout, root_recording:).purchase
  rescue ArgumentError => error
    raise unless error.message == "unsupported commercial lifecycle mode"

    raise "dummy lifecycle mode rejected #{usage_checkout.local_idempotency_key}: #{usage_checkout.items.map { |item| item.commercial_manifest.fetch('canonical_data').slice('product', 'billing_option', 'price') }}"
  end
  RecordingStudioBilling.project_entitlements(root_recording:, source: usage_purchase.effects.first)
  usage_window_starts = Time.current.change(min: 0, sec: 0)
  usage_window_ends = usage_window_starts + 1.hour
  usage_event = RecordingStudioBilling::UsageEvent.find_by(root_recording:, idempotency_key: "seed:usage-event") ||
                RecordingStudioBilling.record_usage(root_recording:, usage_key: "demo_api_calls", quantity: 6,
                                                     idempotency_key: "seed:usage-event", occurred_at: Time.current).event
  raise "dummy usage event could not be recorded" unless usage_event
  usage_window_starts = usage_event.occurred_at.change(min: 0, sec: 0)
  usage_window_ends = usage_window_starts + 1.hour
  meter = refresh_recordable.call(usage_recording_ids.fetch(:meter))
  overage_price = refresh_recordable.call(usage_recording_ids.fetch(:overage_price))
  usage_manifest = RecordingStudioBilling::CommercialManifest.where.not(used_at: nil).order(created_at: :desc).find do |manifest|
    manifest.canonical_data.dig("usage_rating", "meters", meter.recording.id.to_s).present? &&
      manifest.canonical_data.fetch("overage_prices", []).any? do |price|
        price["overage_price_recording_id"] == overage_price.recording.id
      end
  end
  raise "seeded usage manifest is missing approved metering and overage authority" unless usage_manifest
  rating_result = RecordingStudioBilling.rate_usage(root_recording:, meter_recording: meter.recording,
                                                     manifest_digest: usage_manifest.manifest_digest, window_starts_at: usage_window_starts,
                                                     window_ends_at: usage_window_ends)
  rated_usage = rating_result.rated_usage
  raise "dummy usage rating failed: #{rating_result.reason}" unless rated_usage
  allocation = RecordingStudioBilling.allocate_rated_usage(rated_usage:).allocation
  RecordingStudioBilling::CloseUsagePeriod.call(usage_period: allocation.usage_period, at: allocation.usage_period.ends_at)
  RecordingStudioBilling.calculate_overage(allocation:)
  RecordingStudioBilling::FeatureOverrideReviser.call(recording: override.recording, actor: user, attributes: { state: "published" }) unless override.state == "published"

  refund_intent = RecordingStudioBilling.create_refund_intent(
    payment:, root_recording:, local_idempotency_key: "seed:refund", amount_minor: 200, reason: "dummy acceptance refund",
    actor_reference: user.id.to_s, tax_treatment: "provider_default", reversal_policy: "none", line_allocation: {}, metadata: { "seed" => true }
  ).intent
  RecordingStudioBilling::FinancialCommandExecutor.execute(command: refund_intent.financial_command, provider_key: "fake") if refund_intent.financial_command.state == "pending"
  RecordingStudioBilling.project_refund_intent(refund_intent:, root_recording:) unless refund_intent.refund

  adjustment_intent = RecordingStudioBilling.create_adjustment_intent(
    invoice:, root_recording:, local_idempotency_key: "seed:adjustment", kind: "credit", amount_minor: 100,
    reason: "dummy acceptance adjustment", actor_reference: user.id.to_s, tax_treatment: "provider_default",
    affected_reference: { "invoice" => invoice.id }, metadata: { "seed" => true }
  ).intent
  RecordingStudioBilling::FinancialCommandExecutor.execute(command: adjustment_intent.financial_command, provider_key: "fake") if adjustment_intent.financial_command.state == "pending"
  RecordingStudioBilling.project_adjustment_intent(adjustment_intent:, root_recording:) unless adjustment_intent.financial_adjustment

  scheduled_change = RecordingStudioBilling::SubscriptionChangeIntent.find_by(subscription: hybrid_subscription, local_idempotency_key: "seed:scheduled-change") ||
                     RecordingStudioBilling.create_subscription_change_intent(subscription: hybrid_subscription, root_recording:,
                                                                              local_idempotency_key: "seed:scheduled-change", change_kind: "cancellation",
                                                                              effective_at: 1.month.from_now).intent
  applied_change = RecordingStudioBilling::SubscriptionChangeIntent.find_by(subscription: hybrid_subscription, local_idempotency_key: "seed:applied-change") ||
                   RecordingStudioBilling.create_subscription_change_intent(subscription: hybrid_subscription, root_recording:,
                                                                            local_idempotency_key: "seed:applied-change", change_kind: "cancellation").intent
  RecordingStudioBilling::FinancialCommandExecutor.execute(command: applied_change.financial_command, provider_key: "fake") if applied_change.financial_command.state == "pending"

  active_checkout = RecordingStudioBilling::CheckoutIntent.find_by(root_recording:, local_idempotency_key: "seed:active-monthly-checkout") ||
                    RecordingStudioBilling.create_checkout_intent(
                      root_recording:, local_idempotency_key: "seed:active-monthly-checkout", country_code: "US",
                      items: [{ billing_option_recording_id: monthly_option.recording.id, quantity: 1 }]
                    ).intent
  if active_checkout.state == "pending_provider" && active_checkout.financial_command.state == "pending"
    RecordingStudioBilling.execute_checkout_intent(checkout_intent: active_checkout, root_recording:)
  end
  active_command = active_checkout.financial_command
  RecordingStudioBilling.reconcile_provider_command(command: active_command) unless active_command.reload.normalized_result.key?("payment_state")
  RecordingStudioBilling.project_checkout_financial_records(checkout_intent: active_checkout, root_recording:) unless RecordingStudioBilling::Payment.exists?(financial_command: active_command)
  begin
    active_subscription = RecordingStudioBilling.project_completed_checkout_intent(checkout_intent: active_checkout, root_recording:).subscription
  rescue ArgumentError => error
    raise unless error.message == "unsupported commercial lifecycle mode"

    raise "dummy lifecycle mode rejected #{active_checkout.local_idempotency_key}: #{active_checkout.items.map { |item| item.commercial_manifest.fetch('canonical_data').slice('product', 'billing_option', 'price') }}"
  end

  execute_change = lambda do |intent, outcome|
    next unless intent.financial_command.state == "pending"

    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_provider(:fake, RecordingStudioBilling::FakeFinancialAdapter.new(outcome:))
    RecordingStudioBilling::FinancialCommandExecutor.execute(command: intent.financial_command, provider_key: "fake")
  rescue RecordingStudioBilling::FakeFinancialAdapter::TimeoutAfterPossibleSuccess
  ensure
    RecordingStudioBilling.configuration.provider_registry.reset!
    RecordingStudioBilling.register_builtin_providers!
    RecordingStudioBilling.register_provider(:fake, RecordingStudioBilling::DummyFinancialAdapter.new)
  end
  failed_change = RecordingStudioBilling::SubscriptionChangeIntent.find_by(subscription: active_subscription, local_idempotency_key: "seed:failed-change") ||
                  RecordingStudioBilling.create_subscription_change_intent(subscription: active_subscription, root_recording:,
                                                                           local_idempotency_key: "seed:failed-change", change_kind: "cancellation").intent
  execute_change.call(failed_change, :provider_rejection)
  uncertain_change = RecordingStudioBilling::SubscriptionChangeIntent.find_by(subscription: active_subscription, local_idempotency_key: "seed:uncertain-change") ||
                     RecordingStudioBilling.create_subscription_change_intent(subscription: active_subscription, root_recording:,
                                                                              local_idempotency_key: "seed:uncertain-change", change_kind: "cancellation").intent
  execute_change.call(uncertain_change, :timeout_after_possible_success)
  begin
    RecordingStudioBilling.apply_subscription_change_intent(subscription_change_intent: uncertain_change, root_recording:)
  rescue ArgumentError => error
    raise unless error.message == "subscription change provider outcome is requires_review"
  end

  replacement_manifest = RecordingStudioBilling::CommercialManifest.find_by!(manifest_digest: active_subscription.item_versions.first.manifest_digest)
  plan_update_for = lambda do |key, effective_at: nil|
    update = catalogue_recordable.call("RecordingStudioBilling::PlanUpdate", key) ||
             record_child.call(
        RecordingStudioBilling::PlanUpdate.new(
          billing_option_recording: monthly_option.recording, key:, allowance_policy: "preserve", execution_state: "draft",
          replacement_manifest_digest: replacement_manifest.manifest_digest,
          replacement_configuration: { "audience" => { "root_recording_ids" => [root_recording.id] }, "effective_at" => effective_at&.iso8601 }
        ), admin_root_recording, billing_admin.recording
      )
    [update, update.recording.id]
  end
  scheduled_update, scheduled_update_recording_id = plan_update_for.call("demo_plan_update_scheduled", effective_at: 1.month.from_now)
  plan_updates = %w[applied failed uncertain].to_h do |outcome|
    update, recording_id = plan_update_for.call("demo_plan_update_#{outcome}")
    [outcome, recording_id]
  end
  plan_run = lambda do |update, key, outcome: :success|
    preview = RecordingStudioBilling.apply_plan_update(plan_update: update, root_recording: admin_root_recording, idempotency_key: key)
    run = RecordingStudioBilling.apply_plan_update(run: preview, root_recording: admin_root_recording, idempotency_key: key,
                                                   confirmation: { "approved_by" => user.id.to_s })
    run.applications.each { |application| execute_change.call(application.subscription_change_intent, outcome) }
    RecordingStudioBilling.apply_plan_update(run:, root_recording: admin_root_recording, idempotency_key: key)
  end
  scheduled_update = refresh_recordable.call(scheduled_update_recording_id)
  scheduled_preview = RecordingStudioBilling.apply_plan_update(plan_update: scheduled_update, root_recording: admin_root_recording, idempotency_key: "seed:plan-scheduled")
  RecordingStudioBilling.apply_plan_update(run: scheduled_preview, root_recording: admin_root_recording, idempotency_key: "seed:plan-scheduled", confirmation: { "approved_by" => user.id.to_s })
  plan_run.call(refresh_recordable.call(plan_updates.fetch("applied")), "seed:plan-applied")
  plan_run.call(refresh_recordable.call(plan_updates.fetch("failed")), "seed:plan-failed", outcome: :provider_rejection)
  plan_run.call(refresh_recordable.call(plan_updates.fetch("uncertain")), "seed:plan-uncertain", outcome: :timeout_after_possible_success)
  RecordingStudioBilling.apply_subscription_change_intent(subscription_change_intent: applied_change, root_recording:) unless applied_change.reload.state == "applied"

ensure
  Current.actor = previous_actor
end

puts "Seeded: admin@admin.com / Password"
puts "Seeded: Workspace '#{workspace.name}' with root recording ##{root_recording.id}"
puts "Seeded: Admin root '#{admin_root.name}' with root recording ##{admin_root_recording.id}"
puts "Seeded: Billing account '#{account.name}' and billing admin '#{billing_admin.key}'"
puts "Seeded: Fake provider '#{fake_provider.key}' with no credentials or network calls"
puts "Seeded: Stripe test provider '#{stripe_test_provider.key}' with a credential-free configuration probe and no network calls"
puts "Seeded: published checkout pricing for US, UK, IT, DE, and global markets"
puts "Seeded: published metered API-call catalogue with rates, costs, and US overage pricing"
puts "Seeded: free, monthly, annual, quantity-addon, and credit-pack catalogue examples"
puts "Seeded: published plan-update review example"
puts "Seeded: feature override, hybrid subscription, payment, invoice, refund, adjustment, and subscription-change fixtures"
