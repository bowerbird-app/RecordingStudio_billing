# frozen_string_literal: true

module RecordingStudioBilling
  class BillingOption < ApplicationRecord
    include CommercialRecordable

    RECURRENCES = %w[one_time recurring].freeze
    INTERVALS = %w[day week month year].freeze
    QUANTITY_MODES = %w[fixed adjustable].freeze
    PRICING_MODELS = %w[flat per_unit package].freeze
    COLLECTION_METHODS = %w[automatic invoice].freeze
    PRORATION_POLICIES = %w[none prorate].freeze
    LIFECYCLE_POLICIES = %w[immediate scheduled].freeze
    CHECKOUT_POLICIES = %w[allowed required disabled].freeze
    TAX_POLICIES = %w[exclusive inclusive automatic].freeze

    commercial_recordable label: "Billing option", allowed_parent_types: "RecordingStudioBilling::Product"

    belongs_to :product_recording, class_name: "RecordingStudio::Recording", inverse_of: false

    validates :recurrence, inclusion: { in: RECURRENCES }
    validates :interval, inclusion: { in: INTERVALS }, allow_nil: true
    validates :interval_count, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :quantity_mode, inclusion: { in: QUANTITY_MODES }
    validates :minimum_quantity, :maximum_quantity, :default_quantity,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :pricing_model, inclusion: { in: PRICING_MODELS }
    validates :collection_method, inclusion: { in: COLLECTION_METHODS }
    validates :payment_terms_days, :trial_days,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :proration_policy, inclusion: { in: PRORATION_POLICIES }
    validates :lifecycle_policy, inclusion: { in: LIFECYCLE_POLICIES }
    validates :checkout_policy, inclusion: { in: CHECKOUT_POLICIES }
    validates :tax_policy, inclusion: { in: TAX_POLICIES }
    validate :recurrence_matches_interval
    validate :quantity_bounds_are_consistent

    private

    def recurrence_matches_interval
      if recurrence == "recurring"
        errors.add(:interval, "must be present for recurring billing") if interval.blank?
        errors.add(:interval_count, "must be present for recurring billing") if interval_count.blank?
      elsif interval.present? || interval_count.present?
        errors.add(:interval, "must be blank for one-time billing")
      end
    end

    def quantity_bounds_are_consistent
      validate_quantity_bounds
      validate_default_quantity
    end

    def validate_quantity_bounds
      return unless minimum_quantity && maximum_quantity && minimum_quantity > maximum_quantity

      errors.add(:maximum_quantity, "must be greater than or equal to minimum_quantity")
    end

    def validate_default_quantity
      return if default_quantity.blank?

      validate_default_minimum
      validate_default_maximum
    end

    def validate_default_minimum
      return unless minimum_quantity && default_quantity < minimum_quantity

      errors.add(:default_quantity, "must be greater than or equal to minimum_quantity")
    end

    def validate_default_maximum
      return unless maximum_quantity && default_quantity > maximum_quantity

      errors.add(:default_quantity, "must be less than or equal to maximum_quantity")
    end
  end
end
