# frozen_string_literal: true

# Flatpack v0.1.141 still lacks Flatpack #159 billing polish that Billing 0.8/0.9
# already composes against. Until those land on a published tag, restore:
# - PlanSummary `status: nil` / false omits the status badge
# - PlanPicker body Choose plan / disabled Current (no Current badge, no tile footer)
# Remove when Flatpack defines omitted_status? / default_cta_text on the components.
module RecordingStudioBilling
  module FlatPackBillingCompat
    module PlanSummaryOmitStatus
      def initialize(
        plan_name:,
        price_text: nil,
        status: :active,
        renews_on: nil,
        trial_ends_on: nil,
        description: nil,
        **system_arguments
      )
        omit_badge = status.nil? || status == false
        super(
          plan_name: plan_name,
          price_text: price_text,
          status: omit_badge ? :active : status,
          renews_on: renews_on,
          trial_ends_on: trial_ends_on,
          description: description,
          **system_arguments
        )
        @status = nil if omit_badge
      end

      private

      def render_heading_row
        heading = content_tag(:h3, @plan_name, class: "text-lg font-semibold text-[var(--surface-content-color)]")
        return content_tag(:div, heading, class: "mb-2") if @status.nil?

        content_tag(:div, class: "flex items-start justify-between gap-3 mb-2") do
          safe_join([
            heading,
            render(FlatPack::Badge::Component.new(
              text: status_config.fetch(:text),
              style: status_config.fetch(:style),
              size: :sm
            ))
          ])
        end
      end

      def omitted_status?(status)
        status.nil? || status == false
      end
    end

    module PlanPickerBodyCta
      private

      def render_plan_card(item)
        card_classes = []
        card_classes << "border-[var(--color-primary)]" if item[:highlighted] || item[:current]

        render FlatPack::Card::Component.new(
          style: :default,
          class: classes(*card_classes)
        ) do |card|
          card.body do
            safe_join([
              render_plan_heading(item),
              render_plan_price(item),
              render_plan_description(item),
              render_plan_features(item),
              render_plan_cta(item)
            ].compact)
          end
        end
      end

      def render_plan_badges(item)
        return nil unless item[:highlighted]

        render(FlatPack::Badge::Component.new(text: "Popular", style: :primary, size: :sm))
      end

      def render_plan_cta(item)
        return nil unless item[:cta]

        content_tag(:div, class: "mt-4") do
          render FlatPack::Button::Component.new(**plan_cta_arguments(item))
        end
      end

      def plan_cta_arguments(item)
        kwargs = {
          text: item[:cta_text],
          style: item[:current] ? :secondary : :primary,
          class: "w-full"
        }

        if item[:current]
          kwargs[:disabled] = true
        elsif item[:href].present?
          kwargs[:href] = item[:href]
        end

        kwargs
      end

      def normalize_item(item)
        hash = item.respond_to?(:to_h) ? item.to_h : item
        raise ArgumentError, "each plan item must be a Hash" unless hash.is_a?(Hash)

        normalized = hash.transform_keys(&:to_sym)
        raise ArgumentError, "plan item name is required" if normalized[:name].blank?

        show_cta = show_cta?(normalized)

        {
          name: normalized[:name],
          price_text: normalized[:price_text],
          description: normalized[:description],
          features: Array(normalized[:features]),
          href: sanitize_plan_href(normalized[:href]),
          cta: show_cta,
          cta_text: show_cta ? default_cta_text(normalized) : nil,
          current: !!normalized[:current],
          highlighted: !!normalized[:highlighted]
        }
      end

      def show_cta?(normalized)
        return cast_boolean(normalized[:cta]) if normalized.key?(:cta)
        return false if normalized[:cta_text] == false

        true
      end

      def default_cta_text(normalized)
        normalized[:cta_text].presence || (normalized[:current] ? "Current" : "Choose plan")
      end

      def cast_boolean(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end
    end

    def self.apply!
      apply_plan_summary!
      apply_plan_picker!
    end

    def self.apply_plan_summary!
      return unless defined?(FlatPack::Billing::PlanSummary::Component)

      summary = FlatPack::Billing::PlanSummary::Component
      return if summary.method_defined?(:omitted_status?, true)

      summary.prepend(PlanSummaryOmitStatus)
    end

    def self.apply_plan_picker!
      return unless defined?(FlatPack::Billing::PlanPicker::Component)

      picker = FlatPack::Billing::PlanPicker::Component
      return if picker.private_method_defined?(:default_cta_text)

      picker.prepend(PlanPickerBodyCta)
    end
  end
end
