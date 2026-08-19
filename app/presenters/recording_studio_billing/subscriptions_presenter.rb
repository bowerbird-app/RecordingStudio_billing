# frozen_string_literal: true

module RecordingStudioBilling
  class SubscriptionsPresenter < BasePresenter
    attr_accessor :subscriptions, :eligible_options, :change_intents, :account_recording, :plan_options

    def page = :subscriptions

    def plan_cards
      displayed_plan_options.filter_map { |option| plan_card_for(option) }
    end

    def current_subscription
      Array(subscriptions).find { |subscription| subscription.state.to_s.in?(%w[trialing active past_due paused]) }
    end

    def request_rows
      Array(subscriptions).flat_map { |subscription| change_rows(subscription) }
    end

    def current_subscription_rows(subscription)
      return [] unless subscription

      current_subscription_lines(subscription).map do |line|
        terms = canonical_terms(line.commercial_snapshot)
        {
          label: offer_label(
            kind: snapshot_value(terms, "product", "kind") || "plan",
            interval: line.interval,
            recurrence: snapshot_value(terms, "billing_option", "recurrence"),
            name: snapshot_value(terms, "product", "name"),
            amount_minor: line.amount_minor
          ),
          quantity: line.quantity,
          amount: display_amount(line.amount_minor, line.currency_code),
          cadence: cadence_label(snapshot_value(terms, "billing_option", "recurrence") || "recurring", line.interval)
        }
      end
    end

    def change_rows(subscription)
      Array(change_intents).select { |intent| intent.subscription_recording_id == subscription.recording&.id }.map do |intent|
        {
          label: change_kind_label(intent.change_kind),
          state: money_state(intent.state),
          effective: intent.effective_at&.to_fs(:long) || copy("change_effective_after_confirmation", "After provider confirmation")
        }
      end
    end

    def change_kind_label(kind)
      copy("change_kind_#{kind}", kind.to_s.humanize)
    end

    def subscription_label(subscription)
      row = current_subscription_rows(subscription).first
      row&.fetch(:label, nil) || copy("plan_title", "Plan")
    end

    def offer_summary(option)
      [catalog_offer_label(option), cadence_label(option.recurrence, option.interval)].compact.join(" · ")
    end

    private

    def displayed_plan_options
      options = Array(plan_options).presence || published_plan_billing_options.presence || Array(eligible_options)
      sorted_plan_options(options).first(3)
    end

    def published_plan_billing_options
      return [] unless account_recording.is_a?(RecordingStudio::Recording)

      BillingOption.with_current_recording.where(state: "published").select do |option|
        product = option.product_recording&.recordable
        product.is_a?(Product) && product.state == "published" && product.kind == "plan" &&
          option.checkout_policy == "allowed"
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      []
    end

    def sorted_plan_options(options)
      options.sort_by do |option|
        [interval_sort_key(option.interval), live_price_for(option)&.amount_minor.to_i]
      end
    end

    def interval_sort_key(interval)
      { "month" => 0, "year" => 1, "week" => 2 }[interval.to_s] || 3
    end

    def plan_card_for(option)
      price = live_price_for(option)
      amount = price&.amount_minor
      currency = price&.currency_code || "USD"
      exponent = price&.currency_exponent || 2
      product = option.try(:product_recording).try(:recordable)
      current = current_plan_option?(option)
      {
        option:,
        name: offer_label(kind: product.try(:kind) || "plan", interval: option.interval, amount_minor: amount,
                          name: product.try(:name)),
        price_label: amount.nil? ? copy("plan_price_placeholder", "—") : customer_price(amount, currency, exponent:),
        price_suffix: price_interval_suffix(option.interval),
        features: plan_feature_labels(option, amount),
        current:,
        highlighted: current || popular_plan?(option, amount),
        badge: plan_card_badge(option, amount, current),
        checkoutable: !current && option.try(:recording).try(:id).present?,
        quantity_mode: option.quantity_mode,
        default_quantity: option.default_quantity,
        minimum_quantity: option.minimum_quantity,
        maximum_quantity: option.maximum_quantity
      }
    end

    def current_plan_option?(option)
      option_id = option.try(:recording).try(:id)
      product_id = option.try(:product_recording).try(:id) || option.try(:product_recording_id)
      current_plan_lines.any? do |line|
        (option_id.present? && line.try(:billing_option_recording_id) == option_id) ||
          (product_id.present? && line.try(:product_recording_id) == product_id)
      end
    end

    def current_plan_lines
      Array(subscriptions).flat_map { |subscription| current_subscription_lines(subscription) }.select do |line|
        plan_line?(line)
      end
    end

    def popular_plan?(option, amount)
      option.interval.to_s == "month" && amount.to_i.positive? && !current_plan_option?(option)
    end

    def plan_card_badge(option, amount, current)
      return copy("plan_card_current_badge", "Current") if current
      return copy("plan_card_popular_badge", "Popular") if popular_plan?(option, amount)

      nil
    end

    def plan_feature_labels(option, amount)
      features = []
      features << copy("plan_feature_no_charge", "No charge to start") if amount&.zero?
      features << "#{copy('plan_feature_billed_prefix', 'Billed')} #{cadence_label(option.recurrence, option.interval)}"
      features << copy("plan_feature_trial", "#{option.trial_days}-day trial") if option.try(:trial_days).to_i.positive?
      features.concat(catalogue_feature_labels(option))
      features
    end

    def catalogue_feature_labels(option)
      product = option.try(:product_recording).try(:recordable)
      return [] unless product.is_a?(Product)

      Feature.with_current_recording.where(product_recording_id: product.recording.id, state: "published").map do |feature|
        usage_label(feature.key)
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      []
    end

    def live_price_for(option)
      product = option.try(:product_recording).try(:recordable)
      return unless product.is_a?(Product) && account_recording.present?

      resolution = DisplayMarketResolver.call(product:, root_recording:, account_recording:)
      CommercialPriceSelector.new(billing_option: option, market: resolution.market,
                                  currency_code: resolution.currency_code).price!
    rescue ArgumentError, NoMethodError, ActiveRecord::RecordNotFound
      nil
    end
  end
end
