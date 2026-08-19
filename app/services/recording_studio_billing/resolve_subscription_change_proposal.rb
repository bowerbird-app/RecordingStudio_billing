# frozen_string_literal: true

module RecordingStudioBilling
  class ResolveSubscriptionChangeProposal
    def self.call(...) = new(...).call

    KINDS = %w[plan interval addon quantity].freeze
    Proposal = Data.define(:root_recording_id, :schema_version, :resolver_version, :canonical_data,
                           :recording_snapshots, :snapshot_references, :manifest_digest) do
      def persist_and_mark_used!
        attributes = to_h
        manifest = CommercialManifest.find_or_create_by!(manifest_digest:) do |record|
          record.assign_attributes(attributes)
        end
        raise ArgumentError, "subscription proposal terms conflict" unless attributes.all? do |key, value|
          manifest.public_send(key) == value
        end

        manifest.mark_used!
        manifest
      end
    end

    def initialize(subscription:, root_recording:, billing_option_recording_id:, change_kind:, quantity: nil)
      @subscription = subscription
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @billing_option_recording_id = billing_option_recording_id
      @quantity = quantity
      @change_kind = change_kind.to_s
    end

    def call
      subscription = Subscription.recording_for(subscription, root_recording:).reload.recordable
      raise ArgumentError, "unsupported subscription change" unless KINDS.include?(change_kind)

      option = eligible_options(subscription).find do |candidate|
        candidate.recording.id.to_s == billing_option_recording_id.to_s
      end
      raise ActiveRecord::RecordNotFound, "subscription option is unavailable" unless option

      product = option.product_recording.recordable
      validate_change_semantics!(subscription, option, product)
      validate_product_rules!(subscription, product)
      resolution = DisplayMarketResolver.call(product:, root_recording:,
                                              account_recording: subscription.account_recording)
      price = CommercialPriceSelector.new(billing_option: option, market: resolution.market,
                                          currency_code: resolution.currency_code).price!
      manifest = CommercialManifestResolver.new(
        product:, billing_option: option, price:, market: resolution.market, currency_code: resolution.currency_code,
        quantity: quantity.presence || option.default_quantity, account_recording: subscription.account_recording,
        trusted_context: { country_code: resolution.country_code, market_recording_id: resolution.market.recording.id,
                           currency_code: resolution.currency_code, quantity: quantity.presence || option.default_quantity }
      ).resolve!
      Proposal.new(
        product.recording.root_recording_id, CommercialManifest::SCHEMA_VERSION, CommercialManifest::RESOLVER_VERSION,
        manifest.fetch(:canonical_data), manifest.fetch(:recording_snapshots), manifest.fetch(:snapshot_references), manifest.fetch(:manifest_digest)
      )
    end

    private

    attr_reader :billing_option_recording_id, :change_kind, :quantity, :root_recording, :subscription

    def eligible_options(subscription)
      kinds = %w[plan addon]
      CustomerOfferEligibility.call(root_recording:, account_recording: subscription.account_recording, kinds:)
    end

    def validate_change_semantics!(subscription, option, product)
      current_lines = subscription.active_lines.to_a
      current_plan = current_lines.find { |line| line.product_recording.recordable.kind == "plan" }
      provider_ids = current_lines.map(&:provider_account_recording_id).uniq
      unless provider_ids.include?(product.provider_account_recording_id)
        raise ArgumentError,
              "subscription provider is incompatible"
      end

      case change_kind
      when "plan"
        raise ArgumentError, "plan change requires a plan" unless product.kind == "plan"
      when "interval"
        raise ArgumentError, "interval change requires a current plan" unless current_plan && product.kind == "plan"
        raise ArgumentError, "interval change requires the current plan family" unless current_plan.product_recording_id == product.recording.id
      when "addon"
        raise ArgumentError, "addon change requires an addon" unless product.kind == "addon"
      when "quantity"
        existing = current_lines.find { |line| line.billing_option_recording_id == option.recording.id }
        raise ArgumentError, "quantity change requires an existing subscription item" unless existing
        raise ArgumentError, "quantity is fixed for this subscription item" unless option.quantity_mode == "adjustable"
      end

      requested_quantity = Integer(quantity.presence || option.default_quantity, exception: false)
      raise ArgumentError, "subscription quantity is invalid" unless requested_quantity&.positive?
      return unless option.quantity_mode == "adjustable"

      minimum = option.minimum_quantity || 1
      maximum = option.maximum_quantity
      raise ArgumentError, "subscription quantity is below the allowed minimum" if requested_quantity < minimum

      return unless maximum && requested_quantity > maximum

      raise ArgumentError,
            "subscription quantity exceeds the allowed maximum"
    end

    def validate_product_rules!(subscription, proposed_product)
      current_products = subscription.active_lines.filter_map do |line|
        line.product_recording.recordable
      end
      selected_products = case change_kind
                          when "plan", "interval"
                            current_products.reject { |product| product.kind == "plan" } + [proposed_product]
                          when "addon"
                            current_products + [proposed_product]
                          else
                            current_products
                          end
      selected_products.each do |product|
        result = ProductRuleEvaluator.new(product:, selected_products:).evaluate
        raise ArgumentError, "commercial item is ineligible: #{result.violations.join(',')}" unless result.eligible
      end
    end
  end
end
