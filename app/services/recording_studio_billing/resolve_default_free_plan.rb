# frozen_string_literal: true

module RecordingStudioBilling
  class ResolveDefaultFreePlan
    Result = Data.define(:product, :billing_option, :price, :market, :currency_code, :manifest_digest,
                         :commercial_snapshot)

    def self.call(...) = new(...).call

    def initialize(root_recording:, account_recording: nil, product_key: nil, location_context: nil)
      @root_recording = RecordingStudio.root_recording_or_self(root_recording)
      @account_recording = account_recording
      @product_key = product_key || configuration.default_free_plan_product_key
      @location_context = location_context
    end

    def call
      raise ArgumentError, "default free plan product key is not configured" if product_key.blank?

      product = Product.with_current_recording.find_by!(key: product_key, state: "published", kind: "plan")
      billing_option = BillingOption.with_current_recording.find_by!(
        product_recording_id: product.recording.id, state: "published"
      )
      resolution = DisplayMarketResolver.call(product:, root_recording:, account_recording:, location_context:)
      price = CommercialPriceSelector.new(billing_option:, market: resolution.market,
                                          currency_code: resolution.currency_code).price!
      manifest = CommercialManifestResolver.new(
        product:, billing_option:, price:, market: resolution.market, currency_code: resolution.currency_code,
        account_recording: nil,
        trusted_context: {
          country_code: resolution.country_code, market_recording_id: resolution.market.recording.id,
          currency_code: resolution.currency_code, quantity: billing_option.default_quantity || 1
        }
      ).resolve!
      snapshot = commercial_snapshot(manifest)
      Result.new(
        product:, billing_option:, price:, market: resolution.market, currency_code: resolution.currency_code,
        manifest_digest: manifest.fetch(:manifest_digest), commercial_snapshot: snapshot
      )
    end

    private

    attr_reader :account_recording, :location_context, :product_key, :root_recording

    def configuration
      RecordingStudioBilling.configuration
    end

    def commercial_snapshot(manifest)
      {
        "canonical_data" => manifest.fetch(:canonical_data),
        "recording_snapshots" => manifest.fetch(:recording_snapshots),
        "snapshot_references" => manifest.fetch(:snapshot_references)
      }
    end
  end
end
