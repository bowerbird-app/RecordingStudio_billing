# frozen_string_literal: true

# Dummy reference host job. Production hosts enqueue the same public execute
# methods from their own worker. The engine does not ship a job class.
class ExecuteFinancialCommandJob < ApplicationJob
  def perform(command_id)
    command = RecordingStudioBilling::FinancialCommand.find(command_id)
    case command.command_type
    when "checkout"
      intent = RecordingStudioBilling::CheckoutIntent.find_by!(financial_command: command)
      RecordingStudioBilling.execute_checkout_intent(checkout_intent: intent, root_recording: intent.root_recording)
    when "subscription_change"
      intent = RecordingStudioBilling::SubscriptionChangeIntent.find_by!(financial_command: command)
      RecordingStudioBilling.execute_subscription_change_intent(
        subscription_change_intent: intent, root_recording: intent.root_recording
      )
      return unless intent.reload.financial_command&.state == "succeeded"

      RecordingStudioBilling.apply_subscription_change_intent(
        subscription_change_intent: intent, root_recording: intent.root_recording
      )
    end
  end
end
