# frozen_string_literal: true

# The engine keeps provider execution outside the browser request so production
# hosts can run it in their own job system. The dummy app executes only Stripe
# test checkouts inline so a developer can exercise the complete browser flow.
module DummyStripeCheckoutExecution
  def create
    super
    # #region agent log
    begin
      require "json"
      File.open("/opt/cursor/logs/debug.log", "a") do |f|
        f.puts(JSON.generate({ hypothesisId: "B", location: "dummy_stripe_checkout_execution.rb:create", message: "after super", data: { redirect: response.redirect?, status: response.status, location: response.redirect? ? response.location.to_s[0, 120] : nil, checkout_redirect: checkout_redirect? }, timestamp: (Time.now.to_f * 1000).to_i, runId: "post-fix" }))
      end
    rescue StandardError
    end
    # #endregion
    execute_stripe_test_checkout if response.redirect? && checkout_redirect?
  rescue StandardError => error
    # #region agent log
    begin
      require "json"
      File.open("/opt/cursor/logs/debug.log", "a") do |f|
        f.puts(JSON.generate({ hypothesisId: "B", location: "dummy_stripe_checkout_execution.rb:rescue", message: "stripe execute rescued", data: { error_class: error.class.name, error_message: error.message.to_s[0, 200] }, timestamp: (Time.now.to_f * 1000).to_i, runId: "post-fix" }))
      end
    rescue StandardError
    end
    # #endregion
    Rails.logger.error("Stripe test checkout failed: #{error.class}: #{error.message}")
    redirect_to RecordingStudioBilling::PlansPage.path_for(root_recording),
                alert: "Stripe test checkout could not be started."
  end

  private

  def checkout_redirect?
    response.location.to_s.match?(%r{/checkout/[0-9a-f-]+}i)
  end

  def execute_stripe_test_checkout
    return unless DummyStripeTestCredentials.user_flow_enabled?

    request_key = params[:checkout_request_key].to_s
    intent = RecordingStudioBilling::CheckoutIntent.for_root(root_recording).find_by(
      local_idempotency_key: "customer-checkout:#{request_key}"
    )
    # #region agent log
    begin
      require "json"
      File.open("/opt/cursor/logs/debug.log", "a") do |f|
        f.puts(JSON.generate({ hypothesisId: "C", location: "dummy_stripe_checkout_execution.rb:execute", message: "execute gate", data: { found: !intent.nil?, state: intent&.state, adapter: intent&.financial_command&.provider_adapter_key, command_state: intent&.financial_command&.state }, timestamp: (Time.now.to_f * 1000).to_i, runId: "post-fix" }))
      end
    rescue StandardError
    end
    # #endregion
    return unless intent&.financial_command&.provider_adapter_key == "stripe"
    return unless intent.state == "pending_provider" && intent.financial_command.state == "pending"

    RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording:)
  end
end
