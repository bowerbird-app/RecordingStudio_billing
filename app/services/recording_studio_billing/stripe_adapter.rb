# frozen_string_literal: true

require "net/http"
require "stripe"
require "stringio"
require "uri"
require "recording_studio_billing/v1_contract"

module RecordingStudioBilling
  class StripeAdapter
    STRIPE_BROWSER_ORIGINS = %w[
      https://billing.stripe.com
      https://checkout.stripe.com
      https://pay.stripe.com
    ].freeze
    MAX_INVOICE_DOWNLOAD_BYTES = 10 * 1024 * 1024
    DOWNLOAD_OPEN_TIMEOUT = 5
    DOWNLOAD_READ_TIMEOUT = 15

    CAPABILITIES = V1Contract.provider_capabilities.freeze

    attr_reader :capabilities

    def initialize(credential_resolver: nil, trusted_origins_resolver: nil, tax_code_resolver: nil, client_factory: nil)
      raise ArgumentError, "stripe credential resolver must respond to call" if !credential_resolver.nil? && !credential_resolver.respond_to?(:call)
      raise ArgumentError, "stripe trusted origins resolver must respond to call" if !trusted_origins_resolver.nil? && !trusted_origins_resolver.respond_to?(:call)
      raise ArgumentError, "stripe tax code resolver must respond to call" if !tax_code_resolver.nil? && !tax_code_resolver.respond_to?(:call)

      @credential_resolver = credential_resolver
      @trusted_origins_resolver = trusted_origins_resolver || -> { [] }
      @tax_code_resolver = tax_code_resolver
      @client_factory = client_factory || ->(secret_key) { Stripe::StripeClient.new(secret_key) }
      @capabilities = CAPABILITIES
    end

    def call(command:, request:, idempotency_key:)
      credential = credentials
      return no_charge_checkout_response(request) if command.respond_to?(:command_type) &&
                                                     command.command_type == "checkout" && no_charge_checkout?(request)
      return unavailable_response("configuration_missing") unless credential
      return unsupported_response unless command.respond_to?(:command_type)
      return unsupported_response("unsupported_operation") if %w[usage_settlement
                                                                 usage_correction].include?(command.command_type)

      case command.command_type
      when "checkout" then checkout_response(command:, request:, idempotency_key:, credential:)
      when "subscription_change" then subscription_change_response(command:, request:, idempotency_key:, credential:)
      when "refund" then refund_response(command:, request:, idempotency_key:, credential:)
      when "adjustment" then adjustment_response(command:, request:, idempotency_key:, credential:)
      else unsupported_response
      end
    end

    def provider_reference_type(command:, provider_reference:)
      return "checkout.session" if command.command_type == "checkout" && provider_reference.to_s.start_with?("cs_")
      return "subscription" if command.command_type == "subscription_change" && provider_reference.to_s.start_with?("sub_")
      return "refund" if command.command_type == "refund" && provider_reference.to_s.start_with?("re_")

      "invoice" if command.command_type == "adjustment" && provider_reference.to_s.start_with?("in_")
    end

    # Presentation values are intentionally never persisted: they include a
    # Stripe URL or client secret and are valid only for the current browser.
    def checkout_presentation(provider_reference:)
      credential = credentials
      return {} unless credential

      session = stripe_hash(stripe_client(credential).v1.checkout.sessions.retrieve(provider_reference))

      if session["ui_mode"] == "embedded" && session["client_secret"].present?
        { mode: "embedded", client_secret: session["client_secret"],
          publishable_key: credential.fetch(:publishable_key, "") }
      elsif stripe_browser_url?(session["url"])
        mode = if session.dig("metadata", "recording_studio_billing_presentation") == "payment_link"
                 "payment_link"
               else
                 "redirect"
               end
        { mode:, url: session["url"] }
      else
        {}
      end
    rescue StandardError
      {}
    end

    # The caller owns customer authorization and supplies only an opaque Stripe
    # customer reference. The returned URL is transient and must not be stored.
    def portal_session(customer_reference:, return_url:, configuration_id: nil)
      credential = credentials
      return {} unless credential && trusted_return_url?(return_url)

      customer = normalize_reference(customer_reference, "Stripe customer reference")
      params = { "customer" => customer, "return_url" => return_url }
      if configuration_id.present?
        params["configuration"] =
          normalize_reference(configuration_id, "Stripe portal configuration")
      end
      session = stripe_client(credential).v1.billing_portal.sessions.create(params, {})
      url = stripe_hash(session)["url"]
      stripe_browser_url?(url) ? { url: } : {}
    rescue Stripe::StripeError, ArgumentError
      {}
    end

    def trusted_portal_origins
      STRIPE_BROWSER_ORIGINS
    end

    # Returns a readable, non-persistable invoice payload only after both the
    # invoice reference and Stripe-hosted PDF URL have passed validation.
    def invoice_download(invoice:, provider_reference:)
      credential = credentials
      return unless credential && invoice

      reference = normalize_reference(provider_reference, "Stripe invoice reference")
      stripe_invoice = stripe_hash(stripe_client(credential).v1.invoices.retrieve(reference))
      pdf_url = stripe_invoice["invoice_pdf"]
      return unless stripe_invoice_pdf_url?(pdf_url)

      TrustedInvoiceDownload.new(pdf_url)
    rescue Stripe::StripeError, ArgumentError, URI::InvalidURIError, Net::HTTPError
      nil
    end

    # Reconciliation deliberately exposes only a normalized outcome and opaque
    # remote identity; raw provider payloads are not durable engine state.
    def retrieve(command:)
      credential = credentials
      raise ArgumentError, "stripe configuration is missing" unless credential

      reference = normalize_reference(command.provider_reference, "Stripe provider reference")
      remote = retrieve_remote(stripe_client(credential), reference)
      remote_type = remote.fetch("object", command.command_type)
      outcome = stripe_outcome(remote)
      { outcome:, remote_type:, remote_id: reference,
        payload: checkout_financial_payload(remote, command) || { "status" => remote["status"], "object" => remote_type } }
    rescue Stripe::StripeError, ArgumentError
      { outcome: "unknown", remote_type: command.command_type, remote_id: command.provider_reference.to_s, payload: {} }
    end

    # This method receives a host-verified Stripe event envelope. Signature
    # verification belongs at the HTTP boundary, where the raw body exists.
    def verify_webhook(provider_account_recording_id:, environment:, event_id:, remote_type:, remote_id:, payload:)
      event = payload.respond_to?(:to_h) ? payload.to_h.stringify_keys : {}
      raise ArgumentError, "Stripe webhook payload is invalid" unless event["id"].to_s == event_id.to_s

      object = event.dig("data", "object") || {}
      raise ArgumentError, "Stripe webhook object does not match" unless object["id"].to_s == remote_id.to_s

      { provider_account_recording_id:, environment:, event_id:, remote_type:, remote_id: }
    end

    private

    attr_reader :credential_resolver

    def checkout_response(command:, request:, idempotency_key:, credential:)
      checkout = request["request"] || request[:request] || {}
      items = Array(checkout["checkout_items"] || checkout[:checkout_items]).map { |_, item| item }
      return AdapterResponse.new(status: "invalid", result: { "reason" => "checkout_items_missing" }) if items.empty?

      presentation = checkout["presentation"].to_s
      collection_method = (checkout["collection_method"] || checkout[:collection_method]).to_s
      capability = capabilities.evaluate(
        operations: "checkout", currencies: checkout["currency"] || checkout[:currency],
        collection_methods: collection_method.presence || "automatic",
        checkout_modes: presentation, composition: items.one? ? "single" : "mixed"
      )
      return unsupported_checkout_response(capability) unless capability.supported?

      params = {
        "mode" => recurring?(items) ? "subscription" : "payment",
        "line_items" => stripe_line_items(items, checkout.fetch("currency"), native_tax(checkout)),
        "metadata" => { "recording_studio_billing_command" => command.operation_id,
                        "recording_studio_billing_presentation" => presentation }
      }
      apply_native_tax!(params, checkout.fetch("tax", {}), command)
      apply_collection_method!(params, collection_method, checkout, recurring?(items))
      params["ui_mode"] = presentation unless %w[payment_link invoice].include?(presentation)
      if presentation == "embedded" && credential[:return_url].present?
        assign_trusted_url!(params, "return_url",
                            credential[:return_url])
      end
      if %w[redirect payment_link invoice].include?(presentation)
        assign_trusted_url!(params, "success_url", credential[:success_url]) if credential[:success_url].present?
        assign_trusted_url!(params, "cancel_url", credential[:cancel_url]) if credential[:cancel_url].present?
      end
      params["invoice_creation"] ||= { "enabled" => true } if presentation == "invoice" && !recurring?(items)
      session = stripe_client(credential).v1.checkout.sessions.create(params, { idempotency_key: })
      reference = session.id

      AdapterResponse.new(status: "pending", provider_reference: reference,
                          result: { "checkout_session_created" => true, "presentation" => presentation },
                          metadata: { "adapter" => "stripe" }, uncertain_outcome: true)
    rescue Stripe::APIConnectionError
      AdapterResponse.new(status: "pending", result: { "reason" => "provider_timeout" }, uncertain_outcome: true)
    rescue Stripe::AuthenticationError
      AdapterResponse.new(status: "unauthorized", result: { "reason" => "stripe_authentication_failed" })
    rescue Stripe::StripeError => e
      AdapterResponse.new(status: "provider_rejected", result: { "reason" => e.class.name.demodulize.underscore },
                          error_details: { "category" => "stripe_request" })
    rescue KeyError, ArgumentError
      AdapterResponse.new(status: "invalid", result: { "reason" => "checkout_request_invalid" })
    end

    def unsupported_checkout_response(capability)
      status = AdapterResponse::STATUSES.include?(capability.reason) ? capability.reason : "unsupported"
      AdapterResponse.new(status:, result: { "reason" => capability.reason,
                                             "explanation" => capability.explanation,
                                             "constraints" => capability.constraints })
    end

    def subscription_change_response(command:, request:, idempotency_key:, credential:)
      change = command_request(request)
      change_set = change.fetch("change_set", {}).stringify_keys
      subscription = stripe_reference!(change_set, "provider_subscription_reference", "sub_",
                                       "subscription_reference_missing")
      params = case change.fetch("change_kind")
               when "cancellation" then { "cancel_at_period_end" => true }
               when "resumption" then { "cancel_at_period_end" => false }
               when "plan", "interval"
                 item = stripe_reference!(change_set, "provider_subscription_item_reference", "si_",
                                          "subscription_item_reference_missing")
                 price = stripe_reference!(change_set, "provider_price_reference", "price_", "price_reference_missing")
                 { "items" => [{ "id" => item, "price" => price }],
                   "proration_behavior" => proration_behavior!(change) }
               when "quantity"
                 item = stripe_reference!(change_set, "provider_subscription_item_reference", "si_",
                                          "subscription_item_reference_missing")
                 quantity = positive_quantity!(change_set)
                 { "items" => [{ "id" => item, "quantity" => quantity }],
                   "proration_behavior" => proration_behavior!(change) }
               when "addon"
                 addon_params(change_set, change)
               else
                 raise SubscriptionChangeRequestError, "subscription_change_unsupported"
               end
      result = stripe_hash(stripe_client(credential).v1.subscriptions.update(subscription, params,
                                                                             { idempotency_key: }))
      AdapterResponse.new(status: "success", provider_reference: result.fetch("id"),
                          result: { "subscription_changed" => true, "subscription_status" => result["status"] }, metadata: { "adapter" => "stripe" })
    rescue SubscriptionChangeRequestError => e
      AdapterResponse.new(status: "invalid", result: { "reason" => e.message })
    rescue KeyError, ArgumentError
      AdapterResponse.new(status: "invalid", result: { "reason" => "subscription_change_request_invalid" })
    rescue Stripe::StripeError => e
      stripe_error_response(e)
    end

    def refund_response(command:, request:, idempotency_key:, credential:)
      refund = command_request(request)
      payment_reference = normalize_reference(refund.fetch("provider_payment_reference"), "Stripe payment reference")
      result = stripe_hash(stripe_client(credential).v1.refunds.create(
                             { "payment_intent" => payment_reference, "amount" => refund.fetch("amount_minor"),
                               "reason" => refund["reason"] }.compact,
                             { idempotency_key: }
                           ))
      AdapterResponse.new(status: "success", provider_reference: result.fetch("id"), result: {
                            "amount_minor" => result.fetch("amount"), "currency" => result.fetch("currency").upcase,
                            "payment_id" => refund.fetch("payment_id"), "provider_account_recording_id" => command.provider_account_recording_id,
                            "provider_reference" => result.fetch("id")
                          }, metadata: { "adapter" => "stripe" })
    rescue KeyError, ArgumentError
      AdapterResponse.new(status: "invalid", result: { "reason" => "refund_request_invalid" })
    rescue Stripe::StripeError => e
      stripe_error_response(e)
    end

    def adjustment_response(command:, request:, idempotency_key:, credential:)
      adjustment = command_request(request)
      invoice = normalize_reference(adjustment.fetch("provider_invoice_reference"), "Stripe invoice reference")
      params = { "invoice" => invoice, "amount" => adjustment.fetch("amount_minor"),
                 "memo" => adjustment["reason"] }.compact
      result = stripe_hash(stripe_client(credential).v1.credit_notes.create(params, { idempotency_key: }))
      AdapterResponse.new(status: "success", provider_reference: result.fetch("id"), result: {
                            "kind" => adjustment.fetch("kind"), "amount_minor" => adjustment.fetch("amount_minor"),
                            "currency" => adjustment.fetch("currency"), "invoice_id" => adjustment.fetch("invoice_id"),
                            "provider_account_recording_id" => command.provider_account_recording_id,
                            "provider_reference" => result.fetch("id")
                          }, metadata: { "adapter" => "stripe" })
    rescue KeyError, ArgumentError
      AdapterResponse.new(status: "invalid", result: { "reason" => "adjustment_request_invalid" })
    rescue Stripe::StripeError => e
      stripe_error_response(e)
    end

    def command_request(request)
      request.to_h.stringify_keys.fetch("request").to_h.stringify_keys
    end

    def no_charge_checkout?(request)
      checkout = request.to_h.stringify_keys["request"].to_h.stringify_keys
      checkout["presentation"] == "no_charge"
    end

    def no_charge_checkout_response(request)
      checkout = request.to_h.stringify_keys["request"].to_h.stringify_keys
      items = checkout.fetch("checkout_items", {}).values
      return AdapterResponse.new(status: "invalid", result: { "reason" => "no_charge_terms_invalid" }) unless items.any? && items.all? { |item| item.to_h.stringify_keys["amount_minor"].zero? }

      AdapterResponse.new(status: "success", result: { "no_charge" => true, "presentation" => "no_charge" },
                          metadata: { "adapter" => "stripe" })
    end

    def stripe_reference!(change_set, key, prefix, reason)
      value = change_set[key]
      raise SubscriptionChangeRequestError, reason if value.blank?

      reference = normalize_reference(value, "Stripe #{key.tr('_', ' ')}")
      raise SubscriptionChangeRequestError, reason unless reference.start_with?(prefix)

      reference
    end

    def positive_quantity!(change_set)
      quantity = change_set["quantity"]
      raise SubscriptionChangeRequestError, "subscription_quantity_invalid" unless quantity.is_a?(Integer) && quantity.positive?

      quantity
    end

    def proration_behavior!(change)
      policy = change.fetch("proration_policy", "none")
      mapping = { "none" => "none", "create_prorations" => "create_prorations", "always_invoice" => "always_invoice" }
      mapping.fetch(policy) { raise SubscriptionChangeRequestError, "subscription_proration_policy_unsupported" }
    end

    def addon_params(change_set, change)
      action = change_set["addon_action"]
      if action.in?(%w[
                      remove change
                    ])
        item = stripe_reference!(change_set, "provider_subscription_item_reference", "si_",
                                 "subscription_item_reference_missing")
      end
      params = case action
               when "add"
                 price = stripe_reference!(change_set, "provider_price_reference", "price_", "price_reference_missing")
                 { "items" => [{ "price" => price, "quantity" => positive_quantity!(change_set) }] }
               when "remove"
                 { "items" => [{ "id" => item, "deleted" => true }] }
               when "change"
                 price = stripe_reference!(change_set, "provider_price_reference", "price_", "price_reference_missing")
                 { "items" => [{ "id" => item, "price" => price, "quantity" => positive_quantity!(change_set) }] }
               else
                 raise SubscriptionChangeRequestError, "addon_action_unsupported"
               end
      params["proration_behavior"] = proration_behavior!(change)
      params
    end

    def stripe_error_response(error)
      if error.is_a?(Stripe::APIConnectionError)
        return AdapterResponse.new(status: "pending", result: { "reason" => "provider_timeout" },
                                   uncertain_outcome: true)
      end
      if error.is_a?(Stripe::AuthenticationError)
        return AdapterResponse.new(status: "unauthorized",
                                   result: { "reason" => "stripe_authentication_failed" })
      end

      AdapterResponse.new(status: "provider_rejected", result: { "reason" => error.class.name.demodulize.underscore },
                          error_details: { "category" => "stripe_request" })
    end

    def retrieve_remote(client, reference)
      case reference
      when /\Acs_/ then stripe_hash(client.v1.checkout.sessions.retrieve(reference))
      when /\Asub_/ then stripe_hash(client.v1.subscriptions.retrieve(reference))
      when /\Are_/ then stripe_hash(client.v1.refunds.retrieve(reference))
      when /\Ain_/ then stripe_hash(client.v1.invoices.retrieve(reference))
      else raise ArgumentError, "unknown Stripe reference type"
      end
    end

    def stripe_outcome(remote)
      status = remote["payment_status"] || remote["status"]
      return "succeeded" if status.in?(%w[paid succeeded active complete])
      return "failed" if status.in?(%w[failed canceled incomplete_expired])

      "unknown"
    end

    def credentials
      raw = credential_resolver&.call
      case raw
      when String then { secret_key: raw }
      when Hash then raw.symbolize_keys.slice(:secret_key, :publishable_key, :api_base, :return_url, :success_url,
                                              :cancel_url)
      end&.then { |value| value[:secret_key].present? ? value : nil }
    end

    def stripe_line_items(items, currency, tax)
      items.map do |item|
        amount = item["amount_minor"] || item[:amount_minor]
        quantity = item["quantity"] || item[:quantity]
        raise ArgumentError unless amount.is_a?(Integer) && amount >= 0 && quantity.is_a?(Integer) && quantity.positive?

        product = { "name" => "Recording Studio billing item",
                    "metadata" => { "recording_studio_billing_item" => item.fetch("checkout_intent_item_id", item[:checkout_intent_item_id]).to_s,
                                    "recording_studio_billing_manifest" => item.fetch("manifest_digest",
                                                                                      item[:manifest_digest]).to_s }.compact }
        product["tax_code"] = stripe_tax_code(tax) if tax.fetch("enabled", false)
        price_data = { "currency" => currency.to_s.downcase, "unit_amount" => amount, "product_data" => product }
        price_data["tax_behavior"] = tax.fetch("behavior") if tax.fetch("enabled",
                                                                        false) && tax.fetch("behavior") != "provider_default"
        { "price_data" => price_data, "quantity" => quantity }
      end
    end

    def native_tax(checkout)
      tax = checkout.fetch("tax", {}).to_h.stringify_keys
      return { "enabled" => false } if tax.empty? || tax["enabled"] != true

      valid = tax["mode"] == "provider_native" && tax["calculator_key"] == "stripe_tax" &&
              TaxCalculatorCapabilities::BEHAVIORS.include?(tax["behavior"])
      raise ArgumentError, "stripe native tax configuration is invalid" unless valid

      categories = Array(tax["semantic_categories"])
      unless categories.size == 1 && categories.all? do |category|
        category.match?(/\A[a-z][a-z0-9_]*\z/)
      end
        raise ArgumentError,
              "stripe native tax categories are invalid"
      end

      tax.merge("semantic_categories" => categories)
    end

    def apply_collection_method!(params, collection_method, checkout, recurring)
      return unless collection_method == "send_invoice"

      days = Integer(checkout["payment_terms_days"] || checkout[:payment_terms_days] || 30)
      raise ArgumentError unless days >= 0

      if recurring
        params["subscription_data"] = (params["subscription_data"] || {}).merge(
          "collection_method" => "send_invoice", "days_until_due" => [days, 1].max
        )
      else
        invoice_creation = params["invoice_creation"] || { "enabled" => true }
        invoice_data = (invoice_creation["invoice_data"] || {}).merge(
          "collection_method" => "send_invoice", "days_until_due" => [days, 1].max
        )
        params["invoice_creation"] = invoice_creation.merge("enabled" => true, "invoice_data" => invoice_data)
      end
    end

    def apply_native_tax!(params, tax, command)
      return unless tax.to_h.stringify_keys["enabled"] == true

      params["automatic_tax"] = { "enabled" => true }
      params["billing_address_collection"] = "required"
      normalized = tax.to_h.stringify_keys
      if Array(normalized["location_requirements"]).include?("tax_id")
        params["tax_id_collection"] =
          { "enabled" => true }
      end
      params.fetch("metadata")["recording_studio_billing_tax_operation"] = command.operation_id
    end

    def stripe_tax_code(tax)
      category = tax.fetch("semantic_categories").sole
      code = @tax_code_resolver&.call(category)
      SafeFinancialPayload.normalize_reference(code.to_s, label: "Stripe tax code")
    end

    def checkout_financial_payload(remote, command)
      return unless command.command_type == "checkout" && stripe_outcome(remote) == "succeeded"

      totals = remote.slice("amount_subtotal", "amount_discount", "amount_tax", "amount_total", "currency",
                            "payment_status")
      return unless totals.values_at("amount_subtotal", "amount_tax", "amount_total").all? do |value|
        value.is_a?(Integer)
      end

      lines = Array(remote.dig("line_items", "data")).map { |line| normalized_checkout_line(line) }
      return if lines.empty? || lines.any?(&:nil?)

      payload = {
        "subtotal_minor" => totals.fetch("amount_subtotal"), "discount_minor" => totals.fetch("amount_discount", 0),
        "tax_minor" => totals.fetch("amount_tax"), "total_minor" => totals.fetch("amount_total"),
        "currency" => totals.fetch("currency").to_s.upcase, "payment_state" => totals.fetch("payment_status"), "lines" => lines
      }
      tax = command.canonical_request.dig("request", "tax").to_h.stringify_keys
      return payload unless tax["enabled"] == true && tax["mode"] == "provider_native"

      payload.merge(
        "behavior" => tax.fetch("behavior"),
        "breakdown" => [{ "category" => "provider", "amount_minor" => totals.fetch("amount_tax") }],
        "calculator_reference" => command.provider_reference,
        "calculated_at" => Time.at(remote.fetch("created")).iso8601(6)
      )
    rescue KeyError
      nil
    end

    def normalized_checkout_line(line)
      value = stripe_hash(line)
      metadata = value.dig("price", "product",
                           "metadata") || value.dig("price", "product_data", "metadata") || value["metadata"] || {}
      item_id = metadata["recording_studio_billing_item"]
      manifest = metadata["recording_studio_billing_manifest"]
      fields = value.slice("quantity", "amount_subtotal", "amount_discount", "amount_tax", "amount_total")
      return unless item_id.present? && manifest.present? && fields.values.all? { |amount| amount.is_a?(Integer) }

      { "checkout_intent_item_id" => item_id, "manifest_digest" => manifest, "currency" => value.fetch("currency").to_s.upcase,
        "quantity" => value.fetch("quantity"), "unit_amount_minor" => value.fetch("price").fetch("unit_amount"),
        "subtotal_minor" => value.fetch("amount_subtotal"), "discount_minor" => value.fetch("amount_discount"),
        "tax_minor" => value.fetch("amount_tax"), "total_minor" => value.fetch("amount_total") }
    rescue KeyError
      nil
    end

    def recurring?(items)
      items.any? { |item| item["recurrence"] == "recurring" || item[:recurrence] == "recurring" }
    end

    def stripe_client(credential)
      @client_factory.call(credential.fetch(:secret_key))
    end

    def trusted_origins
      Array(@trusted_origins_resolver.call).filter_map { |origin| normalized_origin(origin) }
    end

    def trusted_return_url?(url)
      origin = url_origin(url)
      origin && trusted_origins.include?(origin)
    end

    def stripe_browser_url?(url)
      origin = url_origin(url)
      origin && STRIPE_BROWSER_ORIGINS.include?(origin)
    end

    def stripe_invoice_pdf_url?(url)
      origin = url_origin(url)
      origin && ["https://files.stripe.com", *STRIPE_BROWSER_ORIGINS].include?(origin)
    end

    def assign_trusted_url!(params, key, url)
      raise ArgumentError unless trusted_return_url?(url)

      params[key] = url
    end

    def normalized_origin(value)
      uri = URI.parse(value.to_s)
      return unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil? && uri.path.to_s.in?(["",
                                                                                     "/"]) && uri.query.nil? && uri.fragment.nil?

      uri.origin
    rescue URI::InvalidURIError
      nil
    end

    def url_origin(value)
      uri = URI.parse(value.to_s)
      return unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil?

      uri.origin
    rescue URI::InvalidURIError
      nil
    end

    def normalize_reference(value, label)
      SafeFinancialPayload.normalize_reference(value.to_s, label:)
    end

    def stripe_hash(value)
      value.respond_to?(:to_hash) ? value.to_hash.stringify_keys : value.to_h.stringify_keys
    end

    def unavailable_response(reason)
      AdapterResponse.new(
        status: "provider_unavailable",
        result: { "reason" => reason },
        error_details: { "category" => "provider_unavailable" },
        metadata: { "adapter" => "stripe" }
      )
    end

    def unsupported_response(reason = "operation_not_implemented")
      AdapterResponse.new(
        status: "unsupported",
        result: { "reason" => reason },
        error_details: { "category" => "unsupported" },
        metadata: { "adapter" => "stripe" }
      )
    end

    SubscriptionChangeRequestError = Class.new(ArgumentError)

    class TrustedInvoiceDownload
      def initialize(url)
        @url = URI.parse(url)
      end

      def each
        return enum_for(__method__) unless block_given?

        Net::HTTP.start(@url.host, @url.port, use_ssl: true, open_timeout: DOWNLOAD_OPEN_TIMEOUT,
                                              read_timeout: DOWNLOAD_READ_TIMEOUT) do |http|
          request = Net::HTTP::Get.new(@url.request_uri)
          http.request(request) do |response|
            raise Net::HTTPError.new("Stripe invoice download redirected", response) if response.is_a?(Net::HTTPRedirection)
            raise Net::HTTPError.new("Stripe invoice download failed", response) unless response.is_a?(Net::HTTPSuccess)

            unless response.content_type == "application/pdf"
              raise Net::HTTPError.new("Stripe invoice download is not a PDF",
                                       response)
            end

            length = response["content-length"]&.to_i
            if length && length > MAX_INVOICE_DOWNLOAD_BYTES
              raise Net::HTTPError.new("Stripe invoice download is too large",
                                       response)
            end

            bytes = 0
            response.read_body do |chunk|
              bytes += chunk.bytesize
              if bytes > MAX_INVOICE_DOWNLOAD_BYTES
                raise Net::HTTPError.new("Stripe invoice download is too large",
                                         response)
              end

              yield chunk
            end
          end
        end
      end
    end
  end
end
