# frozen_string_literal: true

RecordingStudioBilling.configure do |config|
  # Stripe is built in and selected by default. Resolve credentials from host-managed secrets at execution time.
  # config.stripe_credential_resolver = -> { Rails.application.credentials.dig(:billing, :stripe) }
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
  # Optional product titles when two plans would otherwise share an interval label:
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
