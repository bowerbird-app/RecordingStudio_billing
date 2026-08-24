# frozen_string_literal: true

module RecordingStudioBilling
  class CurrentPlanComponent < BaseComponent
    def initialize(presenter:)
      super()
      @presenter = presenter
    end

    def row
      @row ||= @presenter.subscription_rows.find { |item| item[:current] } || @presenter.subscription_rows.first
    end

    def plan_name
      return row[:label] if row

      @presenter.copy("no_plan_title", "No plan yet")
    end

    def price_text
      return if row.blank? || row[:price_label].blank?

      "#{row[:price_label]}#{row[:price_suffix]}"
    end

    def plan_description
      return @presenter.copy("no_subscriptions", "No active plan yet. Choose a plan to get started.") unless row
      return if row[:cadence].blank?

      "#{@presenter.copy('plan_feature_billed_prefix', 'Billed')} #{row[:cadence]}"
    end
  end
end
