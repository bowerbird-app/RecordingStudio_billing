# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class RestrictedPortalTest < Minitest::Test
  def test_allows_payment_method_address_tax_id_and_invoice_history
    features = RecordingStudioBilling::RestrictedPortal.validate_features!(
      %w[payment_method_update customer_address customer_tax_id invoice_history]
    )

    assert_equal RecordingStudioBilling::V1Contract::PORTAL_FEATURES, features
  end

  def test_defaults_to_the_restricted_feature_set
    assert_equal RecordingStudioBilling::V1Contract::PORTAL_FEATURES,
                 RecordingStudioBilling::RestrictedPortal.validate_features!(nil)
  end

  def test_rejects_subscription_mutation_and_promotion_features
    %w[subscription_cancel subscription_update subscription_pause promotion_codes].each do |feature|
      error = assert_raises(ArgumentError) { RecordingStudioBilling::RestrictedPortal.validate_features!([feature]) }

      assert_match(/portal cannot change plans/, error.message)
    end
  end

  def test_stripe_configuration_disables_subscription_changes
    features = RecordingStudioBilling::RestrictedPortal.stripe_configuration_features

    assert_equal true, features.dig("payment_method_update", "enabled")
    assert_equal true, features.dig("invoice_history", "enabled")
    assert_equal %w[address tax_id], features.dig("customer_update", "allowed_updates")
    assert_equal false, features.dig("subscription_cancel", "enabled")
    assert_equal false, features.dig("subscription_update", "enabled")
  end

  def test_provider_capabilities_advertise_restricted_portal_features
    capabilities = RecordingStudioBilling::V1Contract.provider_capabilities

    evaluation = capabilities.evaluate(portal_features: RecordingStudioBilling::V1Contract::PORTAL_FEATURES)

    assert_predicate evaluation, :supported?
    refute capabilities.evaluate(portal_features: ["subscription_cancel"]).supported?
  end
end
