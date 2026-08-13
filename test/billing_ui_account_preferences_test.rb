# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require "rails/test_help"

class BillingUiAccountPreferencesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  parallelize(workers: 1)

  setup { BillingTestDatabaseCleanup.clear! }
  teardown { BillingTestDatabaseCleanup.clear! }

  test "preference updates revise the Account recording with normalized safe fields and actor history" do
    root = RecordingStudio.root_recording_for(Workspace.create!(name: "Preferences #{SecureRandom.hex(4)}"))
    actor = User.create!(email: "preferences-#{SecureRandom.hex(4)}@example.com", password: "Password1!",
                         password_confirmation: "Password1!")
    original = RecordingStudioBilling.ensure_account(root_recording: root, name: "Original account")
    recording = original.recording

    current = RecordingStudioBilling::UpdateAccountPreferences.call(
      root_recording: root, account_recording: recording,
      attributes: {
        name: " Revised account ", contact_email: " billing@example.test ", billing_country_code: "it",
        billing_currency_code: "eur", locale: "it-IT", provider_id: "forged", tax_rate: "100"
      }, actor:
    )

    assert_equal "Original account", original.reload.name
    assert_equal "Revised account", current.name
    assert_equal "IT", current.billing_country_code
    assert_equal "EUR", current.billing_currency_code
    assert_equal "billing@example.test", current.contact_email
    refute_respond_to current, :provider_id
    assert_equal current, recording.reload.recordable
    assert_equal 2, RecordingStudioBilling::Account.where(root_recording: root).count
    assert recording.events(actor: actor).exists?
  end
end
