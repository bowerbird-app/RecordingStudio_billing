# frozen_string_literal: true

module RecordingStudioBilling
  class Account < RecordingStudioBilling::ApplicationRecord
    recording_studio_recordable label: "Billing account", root: false

    belongs_to :root_recording, class_name: "RecordingStudio::Recording", inverse_of: false
    has_one :recording, as: :recordable, class_name: "RecordingStudio::Recording", dependent: :restrict_with_error
    scope :with_current_recording, -> { joins(:recording) }

    validates :name, presence: true
    validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
    validates :billing_country_code, :tax_location_country_code, format: { with: /\A[A-Z]{2}\z/ }, allow_blank: true
    validates :billing_currency_code, format: { with: /\A[A-Z]{3}\z/ }, allow_blank: true
    validates :locale, format: { with: /\A[a-z]{2}(?:-[A-Z]{2})?\z/ }, allow_blank: true
    validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) }, allow_blank: true
    validates :tax_location_region_code, format: { with: /\A[A-Za-z0-9_-]{1,16}\z/ }, allow_blank: true
    validates :tax_location_postal_code, format: { with: /\A[A-Za-z0-9 -]{1,32}\z/ }, allow_blank: true
    validate :root_recording_is_a_root

    class << self
      def ensure_account(root_recording:, name: "Billing account")
        EnsureAccount.call(root_recording: root_recording, name: name)
      end
    end

    private

    def root_recording_is_a_root
      return if root_recording.blank?
      return if root_recording.parent_recording_id.blank? && root_recording.root_recording_id == root_recording.id

      errors.add(:root_recording, "must be a root Recording")
    end
  end
end
