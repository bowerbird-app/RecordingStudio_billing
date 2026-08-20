# frozen_string_literal: true

module RecordingStudioBilling
  class EnsureAccount
    def self.call(...)
      new(...).call
    end

    def initialize(root_recording:, name:)
      @root_recording = root_recording
      @name = name
    end

    def call
      Account.transaction do
        root = canonical_root.lock!
        current_account(root) || create_account(root)
      end
    rescue ActiveRecord::RecordNotUnique
      current_account(canonical_root) || raise
    end

    private

    attr_reader :name, :root_recording

    def canonical_root
      root = RecordingStudio.root_recording_or_self(root_recording)
      RecordingStudio.assert_root_recording!(root)
      RecordingStudio::Recording.unscoped.find(root.id)
    end

    def create_account(root)
      account = Account.new(root_recording: root, name: name)
      RecordingStudio.record!(
        action: "created",
        recordable: account,
        root_recording: root,
        parent_recording: root
      )
      Account.with_current_recording.find(account.id)
    end

    def current_account(root)
      Account.with_current_recording.find_by(root_recording: root)
    end
  end
end
