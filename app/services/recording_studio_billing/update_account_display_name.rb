# frozen_string_literal: true

module RecordingStudioBilling
  class UpdateAccountDisplayName
    def self.call(...) = new(...).call

    def initialize(root_recording:, account_recording:, name:, actor: nil)
      @root_recording = root_recording
      @account_recording = account_recording
      @name = name
      @actor = actor
    end

    def call
      UpdateAccountPreferences.call(root_recording:, account_recording:, attributes: { name: }, actor:)
    end

    private

    attr_reader :account_recording, :actor, :name, :root_recording
  end
end
