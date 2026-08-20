# frozen_string_literal: true

module RecordingStudioBilling
  class EnsureBillingAdmin
    def self.call(...)
      new(...).call
    end

    def initialize(root_recording:, key:)
      @root_recording = root_recording
      @key = key
    end

    def call
      BillingAdmin.transaction do
        root = canonical_root.lock!
        current_billing_admin(root) || create_billing_admin(root)
      end
    rescue ActiveRecord::RecordNotUnique
      current_billing_admin(canonical_root) || raise
    end

    private

    attr_reader :key, :root_recording

    def canonical_root
      root = RecordingStudio.root_recording_or_self(root_recording)
      RecordingStudio.assert_root_recording!(root)
      RecordingStudio::Recording.unscoped.find(root.id)
    end

    def create_billing_admin(root)
      billing_admin = BillingAdmin.new(root_recording: root, key: key)
      RecordingStudio.record!(
        action: "created",
        recordable: billing_admin,
        root_recording: root,
        parent_recording: root
      )
      billing_admin
    end

    def current_billing_admin(root)
      BillingAdmin.with_current_recording.find_by(root_recording: root)
    end
  end
end
