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
  # Optional freemium bootstrap from a published $0 plan in your admin catalogue:
  # config.default_free_plan_product_key = "free_plan"
  #
  # Optional app-owned gates (Billing resolves allowances; the host counts usage):
  # config.gates = {
  #   "projects" => { kind: :limit, label: "Projects", count: ->(root:) { Project.for_root(root).count } }
  # }
end
