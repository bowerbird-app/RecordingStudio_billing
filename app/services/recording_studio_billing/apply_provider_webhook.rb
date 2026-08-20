# frozen_string_literal: true

module RecordingStudioBilling
  class ApplyProviderWebhook
    Result = Data.define(:status, :effect) do
      def accepted? = status == :accepted
      def rejected? = status == :rejected
    end

    def self.call(...) = new(...).call

    def self.reject_verified(inbound_event:, kind:)
      new(inbound_event:, remote_type: nil, remote_id: nil).send(:reject!, kind)
    end

    def initialize(inbound_event:, remote_type:, remote_id:,
                   handler_name: ApplyVerifiedProviderWebhook::ACTION_NAME,
                   action_version: ApplyVerifiedProviderWebhook::ACTION_VERSION)
      @inbound_event = inbound_event
      @remote_type = remote_type.to_s
      @remote_id = remote_id.to_s
      @handler_name = handler_name.to_s
      @action_version = action_version.to_s
    end

    def call
      receipt = trusted_receipt
      return Result.new(status: :rejected, effect: nil) unless receipt

      identity = receipt.endpoint.identity.to_h.stringify_keys
      provider_adapter_key = identity.fetch("billing_provider_adapter_key").to_s
      provider_account_id = identity.fetch("billing_provider_account_recording_id")
      environment = identity.fetch("billing_environment").to_s
      return reject!("malformed_verified_webhook") unless receipt.provider_name == provider_adapter_key && receipt.endpoint.provider_name == provider_adapter_key
      return reject!("malformed_verified_webhook") if remote_type.empty? || remote_id.empty?

      adapter = RecordingStudioBilling.configuration.provider_registry.fetch(provider_adapter_key)
      return reject!("provider_verification_unavailable") unless adapter.respond_to?(:verify_webhook)

      trusted = adapter.verify_webhook(
        provider_account_recording_id: provider_account_id, environment:, event_id: receipt.provider_event_id,
        remote_type:, remote_id:, payload: receipt.payload
      )
      return reject!("provider_verification_rejected") unless trusted_identity?(trusted, provider_account_id,
                                                                                environment, receipt.provider_event_id)

      reference = ProviderReference.find_by!(
        provider_adapter_key:, provider_account_recording_id: provider_account_id, environment:, remote_type:, remote_id:
      )
      existing = WebhookEffect.find_by(
        inbound_event_id: receipt.id, provider_account_recording_id: provider_account_id, environment:,
        handler_name:, action_version:
      )
      return Result.new(status: :accepted, effect: existing) if existing

      command = reference.financial_command
      ReconcileProviderCommand.call(command:) if command.command_type == "checkout" || !command.reload.state.in?(%w[
                                                                                                                   succeeded failed cancelled
                                                                                                                 ])
      return reject!("checkout_reconciliation_pending") if command.command_type == "checkout" && !paid_checkout_result?(command)
      return reject!("checkout_projection_incomplete") if command.command_type == "checkout" &&
                                                          !project_checkout!(command, verified: true)

      WebhookEffect.transaction(requires_new: true) do
        reference = ProviderReference.lock.find_by!(
          provider_adapter_key:, provider_account_recording_id: provider_account_id, environment:, remote_type:, remote_id:
        )
        existing = WebhookEffect.lock.find_by(
          inbound_event_id: receipt.id, provider_account_recording_id: provider_account_id, environment:,
          handler_name:, action_version:
        )
        return Result.new(status: :accepted, effect: existing) if existing

        command = reference.financial_command
        return reject!("checkout_reconciliation_pending") if command.command_type == "checkout" && !paid_checkout_result?(command)

        effect = WebhookEffect.create!(
          provider_adapter_key:, event_id: receipt.provider_event_id, inbound_event_id: receipt.id,
          provider_account_recording_id: provider_account_id, environment:, handler_name:, action_version:,
          provider_reference: reference, financial_command: command, processed_at: Time.current,
          safe_payload: { "environment" => environment, "remote_type" => remote_type, "remote_id" => remote_id,
                          "handler" => handler_name }
        )
        Result.new(status: :accepted, effect:)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.new(status: :accepted, effect: WebhookEffect.find_by!(
        inbound_event_id: trusted_receipt.id, provider_account_recording_id: provider_account_id, environment:,
        handler_name:, action_version:
      ))
    rescue ActiveRecord::RecordNotFound
      reject!("unknown_provider_reference")
    rescue KeyError
      reject!("provider_adapter_unavailable")
    rescue ArgumentError
      reject!("provider_verification_rejected")
    rescue StandardError
      reject!("provider_webhook_rejected")
    end

    private

    attr_reader :action_version, :handler_name, :inbound_event, :remote_id, :remote_type

    def trusted_receipt
      return unless defined?(RecordingStudioWebhooks::InboundEvent)
      return unless inbound_event.is_a?(RecordingStudioWebhooks::InboundEvent)

      receipt = RecordingStudioWebhooks::InboundEvent.find_by(id: inbound_event.id)
      return unless receipt&.status&.in?(%w[accepted planned]) && receipt.provider_event_id.present?

      receipt
    end

    def provider_account_id
      trusted_receipt&.endpoint&.identity&.to_h&.stringify_keys&.fetch("billing_provider_account_recording_id", nil)
    end

    def environment
      trusted_receipt&.endpoint&.identity&.to_h&.stringify_keys&.fetch("billing_environment", nil)
    end

    def provider_adapter_key
      trusted_receipt&.endpoint&.identity&.to_h&.stringify_keys&.fetch("billing_provider_adapter_key", nil)
    end

    def reject!(kind)
      receipt = trusted_receipt
      unless receipt && provider_account_id.present? && environment.present?
        return Result.new(status: :rejected,
                          effect: nil)
      end

      ReconciliationIssue.find_or_create_by!(
        provider_adapter_key:, provider_account_recording_id: provider_account_id, environment:, inbound_event_id: receipt.id,
        event_id: receipt.provider_event_id, handler_name:, action_version:, kind:
      ) do |issue|
        issue.authority = "provider"
        issue.safe_payload = {}
      end
      Result.new(status: :rejected, effect: nil)
    end

    def trusted_identity?(value, provider_account_id, environment, event_id)
      identity = value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
      identity == {
        "provider_account_recording_id" => provider_account_id,
        "environment" => environment,
        "event_id" => event_id,
        "remote_type" => remote_type,
        "remote_id" => remote_id
      }
    end

    def project_checkout!(command, verified:)
      return false unless command.reload.command_type == "checkout" && command.state == "succeeded"
      return false unless verified
      return false unless paid_checkout_result?(command)

      intent = CheckoutIntent.find_by(financial_command: command)
      unless intent
        ReconciliationIssue.find_or_create_by!(financial_command: command, authority: "provider",
                                               kind: "checkout_intent_missing") do |issue|
          issue.safe_payload = {}
        end
        return false
      end
      mark_verified_checkout_result!(command)
      begin
        ProjectCheckoutFinancialRecords.call(checkout_intent: intent, root_recording: command.root_recording)
      rescue ArgumentError
        return false
      end
      ProjectCompletedCheckoutIntent.call(checkout_intent: intent, root_recording: command.root_recording)
      checkout_projection_complete?(intent, command)
    end

    def paid_checkout_result?(command)
      return false unless command.reload.state == "succeeded"

      %w[subtotal_minor discount_minor tax_minor total_minor currency lines].all? do |key|
        command.normalized_result.key?(key)
      end && command.normalized_result["payment_state"] == "paid"
    end

    def mark_verified_checkout_result!(command)
      command.with_lock do
        return if command.normalized_result["authority"] == "verified_webhook"

        command.update!(normalized_result: command.normalized_result.merge("authority" => "verified_webhook"))
      end
    end

    def checkout_projection_complete?(intent, command)
      invoice = Invoice.find_by(financial_command: command)
      payment = Payment.find_by(financial_command: command)
      return false unless invoice && payment&.invoice_id == invoice.id && intent.reload.state == "completed"
      return true unless native_tax_checkout?(command)

      TaxCalculation.exists?(financial_command: command)
    end

    def native_tax_checkout?(command)
      tax = command.canonical_request.dig("request", "tax").to_h
      tax["enabled"] == true && tax["mode"] == "provider_native"
    end
  end
end
