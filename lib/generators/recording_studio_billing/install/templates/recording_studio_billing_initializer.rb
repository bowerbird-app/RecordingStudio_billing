# frozen_string_literal: true

RecordingStudioBilling.configure do |config|
  # Stripe is built in and selected by default. Resolve credentials from host-managed secrets at execution time.
  # Production secret values must be restricted keys (`rk_live` / `rk_test`), not full-account `sk_live` keys.
  # Pin Stripe-Version 2026-07-29.dahlia on the Dashboard to match StripeAdapter::STRIPE_API_VERSION.
  # config.stripe_credential_resolver = -> { Rails.application.credentials.dig(:billing, :stripe) }
  #
  # The engine does not enqueue jobs. Register a worker after a pending command is bound:
  # RecordingStudioBilling.configuration.hooks.on(:financial_command_pending) do |command|
  #   ExecuteFinancialCommandJob.perform_later(command.id)
  # end
  #
  # Custom adapters use the same registry API:
  # RecordingStudioBilling.register_provider(:your_provider, YourProviderAdapter.new)
  # config.provider = :your_provider
  #
  # The install generator adds `draw_recording_studio_billing_plans` to routes.rb.
  # Change the path in routes.rb if you want a different URL than /plans.
  config.plans_page_route_helper = :plans_path
  config.plans_page_requires_sign_in = true
  #
  # Put customer-facing titles on Product#name. This map is an offer-label
  # fallback only and does not replace the required column:
  # config.product_display_names = { "pro_monthly" => "Pro", "starter_monthly" => "Starter" }
  #
  # Optional freemium bootstrap from a published $0 plan in your admin catalogue:
  # config.default_free_plan_product_key = "free_plan"
  #
  # Optional app-owned gates (Billing resolves allowances; the host counts usage):
  # config.register_gate(
  #   "pages",
  #   kind: :limit,
  #   label: "Pages",
  #   count: ->(root:) { Page.for_root(root).count }
  # )
  # config.register_gate(
  #   "comments_per_page",
  #   kind: :limit,
  #   label: "Comments",
  #   count: ->(root:, subject:) { subject.comments.count }
  # )
  # Prefer register_gate over replacing config.gates so engines can contribute.
  # Inventory limits use gates; metered API/usage allowances use usage APIs.
  # Plan feature value -1 means unlimited for limit gates.
  # Soft checks: enforce_gate! / gate_allowed? / gate_status
  # Hard checks: require_gate! or enforce_gate!(mode: :hard)
  # Denied copy: gate_message(result) — override via config.billing_copy["gate_limit_reached"] etc.
end
