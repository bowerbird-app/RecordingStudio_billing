# frozen_string_literal: true

module RecordingStudioBilling
  module BillingAdminHubs
    HIGH_SIGNAL_SCREEN_KEYS = {
      "billing" => %w[billing_products billing_plans billing_addons],
      "billing_commercial" => %w[billing_products billing_prices billing_manifests],
      "billing_financial" => %w[billing_invoices billing_payments billing_financial_commands],
      "billing_operations" => %w[billing_subscriptions billing_plan_updates billing_reconciliation_issues]
    }.freeze

    HUB_TABLES = {
      "billing" => {
        title: "Products",
        columns: %i[name key kind state]
      },
      "billing_commercial" => {
        title: "Published manifests",
        columns: %i[manifest_digest used_at created_at]
      },
      "billing_financial" => {
        title: "Financial commands",
        columns: %i[command_type state provider_adapter_key created_at]
      },
      "billing_operations" => {
        title: "Reconciliation issues",
        columns: %i[authority kind state created_at]
      }
    }.freeze

    STAFF_LINKS = {
      "billing" => %w[
        billing_products
        billing_plans
        billing_addons
        billing_options
        billing_prices
        billing_invoices
        billing_payments
        billing_subscriptions
      ]
    }.freeze

    WIDGET_SPECS = [
      { key: "widgets.billing.products", title: "Products", screen: "billing_products",
        description: "Current products in the catalogue.",
        model: "Product", scope: :current, text: :name, trailing: :kind },
      { key: "widgets.billing.plans", title: "Plans", screen: "billing_plans",
        description: "Current plans in the catalogue.",
        model: "Product", scope: :current, kind: "plan", text: :name, trailing: :state },
      { key: "widgets.billing.addons", title: "Add-ons", screen: "billing_addons",
        description: "Current add-ons in the catalogue.",
        model: "Product", scope: :current, kind: "addon", text: :name, trailing: :state },
      { key: "widgets.billing.prices", title: "Prices", screen: "billing_prices",
        description: "Current prices across markets and publication states.",
        model: "Price", scope: :current, text: :key, trailing: :money },
      { key: "widgets.billing.manifests", title: "Published manifests", screen: "billing_manifests",
        description: "Published commercial manifests used at checkout.",
        model: "CommercialManifest", text: :manifest, trailing: :publication },
      { key: "widgets.billing.invoices", title: "Invoices", screen: "billing_invoices",
        description: "Issued and outstanding invoices from checkout and settlement.",
        model: "Invoice", text: :invoice, trailing: :state },
      { key: "widgets.billing.payments", title: "Payments", screen: "billing_payments",
        description: "Captured and pending payments.",
        model: "Payment", text: :payment, trailing: :state },
      { key: "widgets.billing.financial_commands", title: "Financial commands",
        screen: "billing_financial_commands",
        description: "Provider commands waiting on or finished with reconciliation.",
        model: "FinancialCommand", text: :command_and_state },
      { key: "widgets.billing.subscriptions", title: "Subscriptions", screen: "billing_subscriptions",
        description: "Current customer subscriptions.",
        model: "Subscription", scope: :current, text: :identifier, trailing: :state },
      { key: "widgets.billing.plan_updates", title: "Plan updates", screen: "billing_plan_updates",
        description: "Plan update drafts and published replacements.",
        model: "PlanUpdate", scope: :current, text: :key, trailing: :execution_state },
      { key: "widgets.billing.reconciliation_issues", title: "Reconciliation issues",
        screen: "billing_reconciliation_issues",
        description: "Open and resolved provider reconciliation issues.",
        model: "ReconciliationIssue", text: :kind, trailing: :state }
    ].freeze

    PREVIEW_LIMIT = 5
    CATALOGUE_KEY_FILTER_PARAM = :catalogue_key

    module_function

    def inventory_filter_options(filter_key)
      options = { label: filter_key.to_s.humanize }
      options[:param] = CATALOGUE_KEY_FILTER_PARAM if filter_key.to_sym == :key
      options
    end

    def widgets
      @widgets ||= WIDGET_SPECS.map { |spec| build_list_widget(spec) }.freeze
    end

    def install!
      HIGH_SIGNAL_SCREEN_KEYS.each_key { |section_key| install_section!(section_key) }
      install_hub_tables!
    end

    def install_hub_tables!
      HUB_TABLES.each do |section_key, definition|
        screen_class = screen_class_for(section_key)
        next if screen_class.table_value

        screen_class.table do
          title definition.fetch(:title)
          definition.fetch(:columns).each { |column_key| column column_key }
          default_columns(*definition.fetch(:columns))
          default_sort :created_at, direction: :desc
        end
      end
    end

    def install_section!(section_key)
      section_class = section_class_for(section_key)
      reset_section_children!(section_class)
      HIGH_SIGNAL_SCREEN_KEYS.fetch(section_key).each do |screen_key|
        section_class.widget widget_key_for(screen_key), view_variant: :card
      end
      inventory_screen_keys_for(section_key).each do |screen_key|
        title = inventory_link_title(screen_key)
        section_class.link screen_key.to_sym, text: title, url: lambda { |context|
          context.admin_screen_path(screen_key)
        }
      end
      if section_key == "billing_commercial"
        section_class.link :new_product, text: "New product",
                                         url: ->(context) { BillingAdminProductNew.new_url_for(context) },
                                         visible_if: ->(context) { BillingAdminProductNew.create_allowed?(context) }
      end
      hub_title = HUB_TABLES.fetch(section_key).fetch(:title)
      section_class.link :hub, text: hub_title, url: lambda { |context|
        context.admin_screen_path(section_key)
      }
    end

    def widget_key_for(screen_key)
      "widgets.billing.#{screen_key.delete_prefix('billing_')}"
    end

    def inventory_screen_keys_for(section_key)
      high_signal = HIGH_SIGNAL_SCREEN_KEYS.fetch(section_key)
      staff_links = STAFF_LINKS.fetch(section_key, high_signal)
      remaining = ADMIN_OPERATION_AREAS.filter_map do |key, definition|
        next if key.to_s == "billing_feature_overrides"
        next unless section_key == "billing" || definition.fetch(:section) == section_key

        key.to_s
      end
      (staff_links + (remaining - staff_links)).uniq
    end

    def inventory_link_title(screen_key)
      kind_screen = BillingAdminForms::KIND_SCREENS[screen_key.to_s]
      return kind_screen.fetch(:title) if kind_screen

      ADMIN_OPERATION_AREAS.fetch(screen_key.to_sym).fetch(:title)
    end

    def widget_items(spec, context)
      widget_scope(spec).limit(PREVIEW_LIMIT).filter_map do |row|
        text = widget_text(row, spec.fetch(:text))
        next if text.blank?

        item = {
          text: text,
          href: context.admin_screen_path(spec.fetch(:screen))
        }
        item[:trailing] = widget_trailing(row, spec.fetch(:trailing)) if spec.key?(:trailing)
        item.compact
      end
    end

    def widget_rows(spec, _context)
      widget_scope(spec).limit(PREVIEW_LIMIT).to_a
    end

    def widget_scope(spec)
      model = "RecordingStudioBilling::#{spec.fetch(:model)}".constantize
      relation = spec[:scope] == :current ? model.with_current_recording : model.all
      relation = relation.where(kind: spec[:kind]) if spec[:kind]
      relation.order(created_at: :desc)
    end

    def build_list_widget(spec)
      RecordingStudioAdmin::Widget.new(spec.fetch(:key)) do
        type :list
        title spec.fetch(:title)
        description spec.fetch(:description)
        link_label spec.fetch(:title)
        hide_change
        hide_metric
        list_options divider: true, hover: true, compact_preview: :text_summary
        items { |context| BillingAdminHubs.widget_items(spec, context) }
        rows { |context| BillingAdminHubs.widget_rows(spec, context) }
        link_to { |context| context.admin_screen_path(spec.fetch(:screen)) }
      end
    end
    private_class_method :build_list_widget

    def section_class_for(section_key)
      {
        "billing" => BillingSection,
        "billing_commercial" => BillingCommercialSection,
        "billing_financial" => BillingFinancialSection,
        "billing_operations" => BillingOperationsSection
      }.fetch(section_key)
    end
    private_class_method :section_class_for

    def screen_class_for(section_key)
      {
        "billing" => BillingScreen,
        "billing_commercial" => BillingCommercialScreen,
        "billing_financial" => BillingFinancialScreen,
        "billing_operations" => BillingOperationsScreen
      }.fetch(section_key)
    end
    private_class_method :screen_class_for

    def reset_section_children!(section_class)
      section_class.instance_variable_set(:@links_value, [])
      section_class.instance_variable_set(:@widget_keys_value, [])
    end
    private_class_method :reset_section_children!

    def widget_text(row, key)
      case key
      when :manifest then row.manifest_digest.to_s.first(12)
      when :invoice then money_label(row.total_minor, row.currency_code)
      when :payment then money_label(row.amount_minor, row.currency_code)
      when :command_and_state
        [row.command_type, row.state].compact_blank.join(" · ")
      when Symbol then row.public_send(key).to_s
      else key.to_s
      end
    end
    private_class_method :widget_text

    def widget_trailing(row, key)
      case key
      when :money then money_label(row.amount_minor, row.currency_code)
      when :publication then row.used_at? ? "Published" : "Unused"
      when Symbol then row.public_send(key).to_s.presence
      end
    end
    private_class_method :widget_trailing

    def money_label(amount_minor, currency_code)
      [amount_minor, currency_code].compact.join(" ")
    end
    private_class_method :money_label
  end
end
