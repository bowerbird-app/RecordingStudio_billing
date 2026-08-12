# frozen_string_literal: true

module RecordingStudioBilling
  class RateUsage
    Result = Data.define(:status, :aggregation, :rated_usage, :reason) do
      def created? = status == :created
      def existing? = status == :existing
      def denied? = status == :denied
      def unsupported? = status == :unsupported
    end

    def self.call(...) = new(...).call

    def initialize(root_recording:, meter_recording:, manifest_digest:, window_starts_at:, window_ends_at:, metadata: {})
      @root_recording_input = root_recording
      @meter_recording_input = meter_recording
      @manifest_digest = manifest_digest.to_s
      @window_starts_at = window_starts_at
      @window_ends_at = window_ends_at
      @metadata = metadata
    end

    def call
      root, account = authority!
      manifest = CommercialManifest.lock.find_by(manifest_digest:)
      return denied(:missing_meter_authority) unless manifest&.used_at?

      terms = rating_terms(manifest)
      return unsupported(terms) if terms.is_a?(Symbol)
      return denied(:no_entitlement) unless EntitlementAccess.for(root_recording: root, account_recording: account, at: window_ends_at).has_feature?(terms.fetch(:meter).fetch("usage_key"))

      MeterAggregation.transaction(requires_new: true) do
        lock_window!(root, account, terms.fetch(:meter).fetch("meter_recording_id"))
        events = usage_events(root, account, terms.fetch(:meter).fetch("usage_key"))
        return denied(:no_usage) if events.empty?

        aggregation = aggregate(root, account, terms, events)
        existing = RatedUsage.find_by(meter_aggregation: aggregation)
        return Result.new(status: :existing, aggregation:, rated_usage: existing, reason: nil) if existing

        rated = RatedUsage.create!(rated_attributes(root, account, aggregation, terms))
        Result.new(status: :created, aggregation:, rated_usage: rated, reason: nil)
      end
    rescue ActiveRecord::RecordNotUnique
      retry_existing_result
    rescue ArgumentError, TypeError, SafeFinancialPayload::UnsafeValue
      unsupported(:invalid_rate_terms)
    end

    private

    attr_reader :manifest_digest, :metadata, :meter_recording_input, :root_recording_input, :window_ends_at, :window_starts_at

    def authority!
      root = RecordingStudio.root_recording_or_self(root_recording_input)
      RecordingStudio.assert_root_recording!(root)
      root = RecordingStudio::Recording.unscoped.find(root.id)
      account = Account.with_current_recording.find_by!(root_recording: root).recording
      unless account.recordable_type == "RecordingStudioBilling::Account" && account.root_recording_id == root.id && account.parent_recording_id == root.id
        raise ArgumentError, "billing account must belong directly to the normalized root"
      end
      raise ArgumentError, "rating window is invalid" unless window_starts_at.respond_to?(:to_time) && window_ends_at.respond_to?(:to_time) && window_ends_at.to_time > window_starts_at.to_time

      [root, account]
    end

    def rating_terms(manifest)
      rating = manifest.canonical_data.fetch("usage_rating")
      meter_id = meter_recording_input.respond_to?(:id) ? meter_recording_input.id.to_s : meter_recording_input.to_s
      meter = rating.fetch("meters")[meter_id]
      return :missing_meter_authority unless meter.is_a?(Hash) && meter["meter_recording_id"] == meter_id

      unit_id = meter.fetch("usage_unit_recording_id")
      rates = rating.fetch("rates").values.select { |rate| rate["usage_unit_recording_id"] == unit_id }
      return :missing_rate_authority if rates.empty?
      return :ambiguous_rate_terms unless rates.one?
      rate = rates.sole
      return :missing_rate_authority unless rating.fetch("rate_cards").key?(rate.fetch("rate_card_recording_id"))

      customer_rates = rating.fetch("customer_rates").values.select { |price| price["usage_unit_recording_id"] == unit_id }
      return :missing_rate_authority if customer_rates.empty?
      return :ambiguous_rate_terms unless customer_rates.one?
      cost_rates = rating.fetch("cost_rates").values.select { |cost| cost["usage_unit_recording_id"] == unit_id }
      return :ambiguous_rate_terms if cost_rates.many?
      cost_rate = cost_rates.first
      return :missing_rate_authority if cost_rate && !rating.fetch("cost_cards").key?(cost_rate.fetch("cost_card_recording_id"))

      { meter:, rate:, customer_rate: customer_rates.sole, cost_rate:, manifest: }
    rescue KeyError, TypeError
      :missing_rate_authority
    end

    def usage_events(root, account, usage_key)
      UsageEvent.where(root_recording: root, account_recording: account, usage_key:)
                .where(occurred_at: window_starts_at.to_time...window_ends_at.to_time).order(:occurred_at, :id).to_a
    end

    def aggregate(root, account, terms, events)
      meter = terms.fetch(:meter)
      snapshot = SafeFinancialPayload.normalize({
        "meter_recording_id" => meter.fetch("meter_recording_id"), "usage_unit_recording_id" => meter.fetch("usage_unit_recording_id"),
        "aggregation" => meter.fetch("aggregation"), "window_starts_at" => window_starts_at.to_time.utc.iso8601(6),
        "window_ends_at" => window_ends_at.to_time.utc.iso8601(6),
        "events" => events.map { |event| { "id" => event.id, "quantity" => event.quantity } }
      })
      digest = database_snapshot_digest(snapshot)
      attributes = {
        root_recording: root, account_recording: account, meter_recording_id: meter.fetch("meter_recording_id"),
        usage_unit_recording_id: meter.fetch("usage_unit_recording_id"), manifest_digest:, aggregation: meter.fetch("aggregation"),
        window_starts_at: window_starts_at.to_time, window_ends_at: window_ends_at.to_time, aggregated_at: Time.current,
        quantity: aggregate_quantity(meter.fetch("aggregation"), events), event_count: events.size, usage_event_ids: events.map(&:id), input_digest: digest,
        input_snapshot: snapshot, safe_metadata: SafeFinancialPayload.normalize(metadata)
      }
      MeterAggregation.find_or_create_by!(attributes.slice(:root_recording, :account_recording, :meter_recording_id, :window_starts_at, :window_ends_at, :manifest_digest, :input_digest)) { |row| row.assign_attributes(attributes) }
    end

    def aggregate_quantity(mode, events)
      case mode
      when "sum" then events.sum(&:quantity)
      when "count" then events.size
      when "maximum" then events.map(&:quantity).max
      when "latest" then events.last.quantity
      else raise ArgumentError, "unsupported aggregation"
      end
    end

    def rated_attributes(root, account, aggregation, terms)
      quantity = converted_quantity(aggregation.quantity, terms.fetch(:rate))
      customer = money_for(quantity, terms.fetch(:customer_rate), package: true)
      cost = terms.fetch(:cost_rate) && money_for(quantity, terms.fetch(:cost_rate), package: false)
      snapshot = SafeFinancialPayload.normalize({
        "meter" => terms.fetch(:meter), "rate" => terms.fetch(:rate), "customer_rate" => terms.fetch(:customer_rate), "cost_rate" => terms.fetch(:cost_rate)
      }, allow_authoritative_totals: true)
      {
        root_recording: root, account_recording: account, meter_aggregation: aggregation, manifest_digest:,
        rate_recording_id: terms.fetch(:rate).fetch("rate_recording_id"), customer_price_recording_id: terms.fetch(:customer_rate).fetch("customer_price_recording_id"), cost_rate_recording_id: terms.fetch(:cost_rate)&.fetch("cost_rate_recording_id"),
        rate_card_recording_id: terms.fetch(:rate).fetch("rate_card_recording_id"), cost_card_recording_id: terms.fetch(:cost_rate)&.fetch("cost_card_recording_id"),
        quantity:, customer_amount_minor: customer.fetch(:amount_minor), customer_currency_code: customer.fetch(:currency_code), customer_currency_exponent: customer.fetch(:currency_exponent),
        cost_amount_minor: cost&.fetch(:amount_minor), cost_currency_code: cost&.fetch(:currency_code), cost_currency_exponent: cost&.fetch(:currency_exponent),
        window_starts_at: aggregation.window_starts_at, window_ends_at: aggregation.window_ends_at, rated_at: Time.current,
        aggregation_snapshot: SafeFinancialPayload.normalize(aggregation.input_snapshot), rate_snapshot: snapshot,
        safe_metadata: SafeFinancialPayload.normalize(metadata)
      }
    end

    def converted_quantity(quantity, rate)
      numerator = Integer(rate.fetch("conversion_numerator"))
      denominator = Integer(rate.fetch("conversion_denominator"))
      raise ArgumentError, "rate conversion is invalid" unless numerator.positive? && denominator.positive?

      converted = quantity * numerator
      raise ArgumentError, "rate conversion is non-integral" unless (converted % denominator).zero?

      converted / denominator
    rescue KeyError, ArgumentError, TypeError
      raise ArgumentError, "rate conversion is unsupported" if rate["conversion_decimal"].present?

      raise
    end

    def money_for(quantity, terms, package:)
      amount = Integer(terms.fetch("amount_minor"))
      raise ArgumentError, "rate amount is invalid" if amount.negative?
      multiplier = if package && terms.fetch("pricing_model") == "package"
                     size = Integer(terms.fetch("package_size"))
                     raise ArgumentError, "package quantity is non-integral" unless size.positive? && (quantity % size).zero?
                     quantity / size
                   elsif !package || terms.fetch("pricing_model") == "per_unit"
                     quantity
                   else
                     raise ArgumentError, "pricing model is unsupported"
                   end
      { amount_minor: amount * multiplier, currency_code: terms.fetch("currency_code"), currency_exponent: Integer(terms.fetch("currency_exponent")) }
    end

    def lock_window!(root, account, meter_id)
      key = "recording-studio-billing:rating:#{root.id}:#{account.id}:#{meter_id}:#{window_starts_at.to_time.utc.iso8601(6)}:#{window_ends_at.to_time.utc.iso8601(6)}"
      quoted_key = MeterAggregation.connection.quote(key)
      MeterAggregation.connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))")
    end

    def database_snapshot_digest(snapshot)
      json = MeterAggregation.connection.quote(snapshot.to_json)
      MeterAggregation.connection.select_value("SELECT encode(digest(#{json}::jsonb::text, 'sha256'), 'hex')")
    end

    def denied(reason) = Result.new(status: :denied, aggregation: nil, rated_usage: nil, reason:)
    def unsupported(reason) = Result.new(status: :unsupported, aggregation: nil, rated_usage: nil, reason:)

    def retry_existing_result
      aggregation = MeterAggregation.where(manifest_digest:, window_starts_at: window_starts_at.to_time, window_ends_at: window_ends_at.to_time).order(created_at: :desc).first
      rated = aggregation && RatedUsage.find_by(meter_aggregation: aggregation)
      return Result.new(status: :existing, aggregation:, rated_usage: rated, reason: nil) if rated

      raise
    end
  end
end