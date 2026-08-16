# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

require_relative "dummy_v1_catalogue"

result = DummyV1Catalogue.call

puts "Seeded: admin@admin.com / Password"
puts "Seeded: Workspace '#{result.workspace.name}' with root recording ##{result.root_recording.id}"
puts "Seeded: Admin root '#{result.admin_root.name}' with root recording ##{result.admin_root_recording.id}"
puts "Seeded: Billing account '#{result.account.name}' and billing admin '#{result.billing_admin.key}'"
puts "Seeded: Fake provider '#{result.fake_provider.key}' with no credentials or network calls"
puts "Seeded: Stripe test provider '#{result.stripe_test_provider.key}' with a credential-free configuration probe and no network calls"
puts "Seeded: published products and market prices for US, UK, Italy, Germany, and global"
puts "Seeded: metered API-call service with allowance, rates, costs, and US overage caps"
puts "Seeded: free, monthly, annual (with trial), quantity-addon, and prepaid credit-pack examples"
puts "Seeded: checkout presentations, hybrid subscription, usage, refund, adjustment, and reconciliation fixtures"
