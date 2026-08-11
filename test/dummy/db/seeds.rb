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
  result = RecordingStudio.record!(action: "created", recordable:, root_recording: root, parent_recording: parent)
  RecordingStudio::Recording.unscoped.find(result.recording.id).recordable
end

previous_actor = Current.actor
Current.actor = user

begin
  provider = RecordingStudioBilling::ProviderAccount.with_current_recording.find_by(key: "demo_checkout_provider") ||
             record_child.call(
               RecordingStudioBilling::ProviderAccount.new(
                 billing_admin_recording: billing_admin.recording, key: "demo_checkout_provider", adapter_key: "stripe",
                 name: "Demo checkout provider", environment: "test", configuration: {}, capabilities: [],
                 supported_markets: %w[US GB IT DE AQ], supported_currencies: %w[USD GBP EUR]
               ), admin_root_recording, billing_admin.recording
             )
  product = RecordingStudioBilling::Product.with_current_recording.find_by(key: "demo_checkout_product") ||
            record_child.call(
              RecordingStudioBilling::Product.new(
                provider_account_recording: provider.recording, key: "demo_checkout_product", kind: "service", feature_values: {}
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
    "demo_us_market" => { countries: ["US"], currency: "USD", amount: 1_200, fallback: false },
    "demo_uk_market" => { countries: ["GB"], currency: "GBP", amount: 900, fallback: false },
    "demo_it_market" => { countries: ["IT"], currency: "EUR", amount: 1_000, fallback: false },
    "demo_de_market" => { countries: ["DE"], currency: "EUR", amount: 1_100, fallback: false },
    "demo_global_market" => { countries: ["AQ"], currency: "USD", amount: 1_300, fallback: true }
  }
  prices = market_specs.map do |market_key, spec|
    market = RecordingStudioBilling::Market.with_current_recording.find_by(key: market_key) ||
             record_child.call(
               RecordingStudioBilling::Market.new(
                 provider_account_recording: provider.recording, key: market_key, country_codes: spec[:countries], country_groups: {},
                 allowed_currency_codes: [spec[:currency]], default_currency_code: spec[:currency], priority: 10, specificity: 1,
                 fallback: spec[:fallback], ppa_policy: "standard", rounding_policy: "half_up", tax_presentation_policy: "exclusive",
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
  unpublished_price_ids = prices.reject { |price| price.state == "published" }.map { |price| price.recording.id }
  RecordingStudioBilling::CommercialPublisher.publish!(root_recording: admin_root_recording, price_recording_ids: unpublished_price_ids, actor: user) if unpublished_price_ids.any?
ensure
  Current.actor = previous_actor
end

puts "Seeded: admin@admin.com / Password"
puts "Seeded: Workspace '#{workspace.name}' with root recording ##{root_recording.id}"
puts "Seeded: Admin root '#{admin_root.name}' with root recording ##{admin_root_recording.id}"
puts "Seeded: Billing account '#{account.name}' and billing admin '#{billing_admin.key}'"
puts "Seeded: published demo checkout pricing for US, UK, IT, DE, and global markets"
