# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/environment"

class BillingControllerCheckoutSelectionTest < Minitest::Test
  def test_selection_requires_an_opaque_request_key_and_items
    controller = controller_with(params: {})

    assert_raises(ActionController::ParameterMissing) { controller.send(:checkout_selection) }
  end

  def test_selection_rejects_client_authoritative_and_unknown_item_fields
    controller = controller_with(
      params: {
        checkout_request_key: SecureRandom.hex(16),
        items: { "0" => { billing_option_recording_id: "option", amount_minor: "1", provider: "forged" } }
      }
    )

    assert_raises(ArgumentError) { controller.send(:checkout_selection) }
  end

  def test_selection_accepts_only_option_identifier_and_quantity
    request_key = SecureRandom.hex(16)
    controller = controller_with(
      params: {
        checkout_request_key: request_key,
        country_code: "IT",
        items: { "0" => { billing_option_recording_id: "option", quantity: "2" } }
      }
    )

    selection = controller.send(:checkout_selection)

    assert_equal request_key, selection.fetch(:request_key)
    assert_equal [{ "billing_option_recording_id" => "option", "quantity" => 2 }], selection.fetch(:items)
    assert_equal "IT", selection.fetch(:country_code)
  end

  private

  def controller_with(params:)
    controller = RecordingStudioBilling::CheckoutSelectionsController.new
    controller.define_singleton_method(:params) { ActionController::Parameters.new(params) }
    controller
  end
end
