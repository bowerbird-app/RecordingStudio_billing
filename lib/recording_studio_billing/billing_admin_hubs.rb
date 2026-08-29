# frozen_string_literal: true

module RecordingStudioBilling
  module BillingAdminHubs
    HIGH_SIGNAL_SCREEN_KEYS = {
      "billing_commercial" => %w[billing_products billing_prices billing_manifests],
      "billing_financial" => %w[billing_invoices billing_payments billing_financial_commands],
      "billing_operations" => %w[billing_subscriptions billing_plan_updates billing_reconciliation_issues]
    }.freeze

    HUB_TABLES = {
      "billing_commercial" => {
        title: "Published manifests",
        columns: %i[manifest_digest used_at created_at]
      },
      "billing_financial" => {
        title: "Plan changes",
        columns: %i[command_type state provider_adapter_key created_at]
      },
      "billing_operations" => {
        title: "Reconciliation issues",
        columns: %i[authority kind state created_at]
      }
    }.freeze

    WIDGET_SPECS = [
      { key: "widgets.billing.products", title: "Products", screen: "billing_products",
        description: "Current products in the published and draft commercial graph.",
        model: "Product", scope: :current, text: :product_name, trailing: :product_kind },
      { key: "widgets.billing.prices", title: "Prices", screen: "billing_prices",
        description: "Current prices across markets and publication states.",
        model: "Price", scope: :current, text: :price_offer, trailing: nil },
      { key: "widgets.billing.manifests", title: "Published manifests", screen: "billing_manifests",
        description: "Published commercial manifests used at checkout.",
        model: "CommercialManifest", text: :manifest_offer, trailing: :publication },
      { key: "widgets.billing.invoices", title: "Invoices", screen: "billing_invoices",
        description: "Issued and outstanding invoices from checkout and settlement.",
        model: "Invoice", text: :invoice, trailing: :money_state },
      { key: "widgets.billing.payments", title: "Payments", screen: "billing_payments",
        description: "Captured and pending payments.",
        model: "Payment", text: :payment, trailing: :money_state },
      { key: "widgets.billing.financial_commands", title: "Plan changes",
        screen: "billing_financial_commands",
        description: "Provider commands waiting on or finished with reconciliation.",
        model: "FinancialCommand", text: :command_and_state },
      { key: "widgets.billing.subscriptions", title: "Subscriptions", screen: "billing_subscriptions",
        description: "Current customer subscriptions.",
        model: "Subscription", scope: :current, text: :subscription_label, trailing: :lifecycle_state },
      { key: "widgets.billing.plan_updates", title: "Plan updates", screen: "billing_plan_updates",
        description: "Plan update drafts and published replacements.",
        model: "PlanUpdate", scope: :current, text: :plan_update_label, trailing: :lifecycle_state },
      { key: "widgets.billing.reconciliation_issues", title: "Reconciliation issues",
        screen: "billing_reconciliation_issues",
        description: "Open and resolved provider reconciliation issues.",
        model: "ReconciliationIssue", text: :reconciliation_kind, trailing: :lifecycle_state }
    ].freeze

    PREVIEW_LIMIT = 5
    CATALOGUE_KEY_FILTER_PARAM = :catalogue_key

    module_function

    def inventory_filter_options(filter_key)
      options = { label: filter_key.to_s.humanize }
      options[:param] = CATALOGUE_KEY_FILTER_PARAM if filter_key.to_sym == :key
      options
    end

    def inventory_column_options(screen_key, column_key)
      case column_key.to_sym
      when :kind
        if screen_key.to_s == "billing_products"
          { value: ->(row, _) { DisplayFormatters.product_kind_label(row.kind) } }
        elsif screen_key.to_s == "billing_reconciliation_issues"
          { value: ->(row, _) { DisplayFormatters.reconciliation_kind_label(row.kind) } }
        else
          { value: ->(row, _) { DisplayFormatters.title_case_key(row.kind) } }
        end
      when :state, :execution_state
        { value: ->(row, _) { DisplayFormatters.admin_state_label(row.public_send(column_key)) } }
      when :command_type
        { value: ->(row, _) { DisplayFormatters.command_type_label(row.command_type) } }
      when :amount_minor
        { value: lambda { |row, _|
          DisplayFormatters.format_money(row.amount_minor, row.try(:currency_code),
                                         exponent: row.try(:currency_exponent) || 2)
        } }
      when :total_minor
        { value: lambda { |row, _|
          DisplayFormatters.format_money(row.total_minor, row.try(:currency_code),
                                         exponent: row.try(:currency_exponent) || 2)
        } }
      else
        {}
      end
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
          definition.fetch(:columns).each do |column_key|
            column column_key, **hub_table_column_options(section_key, column_key)
          end
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
        title = ADMIN_OPERATION_AREAS.fetch(screen_key.to_sym).fetch(:title)
        section_class.link screen_key.to_sym, text: title, url: lambda { |context|
          context.admin_screen_path(screen_key)
        }
      end
      if section_key == "billing_commercial"
        section_class.link :new_product, text: "New product", url: lambda { |context|
          context.admin_screen_path(BillingAdminProductNew::SCREEN_KEY)
        }
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
      remaining = ADMIN_OPERATION_AREAS.filter_map do |key, definition|
        next if key.to_s == "billing_feature_overrides"
        next unless definition.fetch(:section) == section_key

        key.to_s
      end
      (high_signal + (remaining - high_signal)).uniq
    end

    def widget_items(spec, context)
      widget_scope(spec).limit(PREVIEW_LIMIT).filter_map do |row|
        text = widget_text(row, spec.fetch(:text))
        next if text.blank?

        item = {
          text: text,
          href: context.admin_screen_path(spec.fetch(:screen))
        }
        trailing_key = spec[:trailing]
        if trailing_key
          trailing = widget_trailing(row, trailing_key)
          item[:trailing] = trailing if trailing.present?
        end
        item.compact
      end
    end

    def widget_rows(spec, _context)
      widget_scope(spec).limit(PREVIEW_LIMIT).to_a
    end

    def widget_scope(spec)
      model = "RecordingStudioBilling::#{spec.fetch(:model)}".constantize
      relation = spec[:scope] == :current ? model.with_current_recording : model.all
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
        "billing_commercial" => BillingCommercialSection,
        "billing_financial" => BillingFinancialSection,
        "billing_operations" => BillingOperationsSection
      }.fetch(section_key)
    end
    private_class_method :section_class_for

    def screen_class_for(section_key)
      {
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

    def hub_table_column_options(section_key, column_key)
      case [section_key, column_key]
      when %w[billing_financial command_type]
        { value: ->(row, _) { DisplayFormatters.command_type_label(row.command_type) } }
      when %w[billing_financial state], %w[billing_operations state]
        { value: ->(row, _) { DisplayFormatters.admin_state_label(row.state) } }
      when %w[billing_operations kind]
        { value: ->(row, _) { DisplayFormatters.reconciliation_kind_label(row.kind) } }
      else
        {}
      end
    end
    private_class_method :hub_table_column_options

    def widget_text(row, key)
      case key
      when :product_name then row.name.presence || row.key.to_s
      when :price_offer then price_offer_label(row)
      when :manifest_offer then manifest_offer_label(row)
      when :invoice then money_label(row.total_minor, row.currency_code)
      when :payment then money_label(row.amount_minor, row.currency_code)
      when :command_and_state
        [
          DisplayFormatters.command_type_label(row.command_type),
          DisplayFormatters.admin_state_label(row.state)
        ].compact_blank.join(" · ")
      when :subscription_label then subscription_label(row)
      when :plan_update_label then plan_update_label(row)
      when :reconciliation_kind then DisplayFormatters.reconciliation_kind_label(row.kind)
      when Symbol then row.public_send(key).to_s
      else key.to_s
      end
    end
    private_class_method :widget_text

    def widget_trailing(row, key)
      case key
      when :product_kind then DisplayFormatters.product_kind_label(row.kind)
      when :money then money_label(row.amount_minor, row.currency_code)
      when :publication then row.used_at? ? "Published" : "Unused"
      when :money_state then DisplayFormatters.admin_state_label(row.state)
      when :lifecycle_state
        state = row.try(:execution_state).presence || row.try(:state)
        DisplayFormatters.admin_state_label(state) if state.present?
      when Symbol then row.public_send(key).to_s.presence
      end
    end
    private_class_method :widget_trailing

    def money_label(amount_minor, currency_code, exponent: 2)
      DisplayFormatters.format_money(amount_minor, currency_code, exponent:)
    end
    private_class_method :money_label

    def price_offer_label(price)
      name = commercial_product_name(price.billing_option_recording&.recordable)
      money = money_label(price.amount_minor, price.currency_code, exponent: price.try(:currency_exponent) || 2)
      return if name.blank? && money.blank?
      return money if name.blank?

      "#{name} · #{money}"
    end
    private_class_method :price_offer_label

    def manifest_offer_label(manifest)
      name = manifest_product_name(manifest)
      date = DisplayFormatters.format_date(manifest.used_at || manifest.created_at)
      return if name.blank?

      [name, date].compact.join(" · ")
    end
    private_class_method :manifest_offer_label

    def manifest_product_name(manifest)
      data = manifest.canonical_data
      return unless data.is_a?(Hash)

      product = data["product"] || data[:product]
      key = product.is_a?(Hash) ? (product["key"] || product[:key]) : nil
      name_from_product_key(key).presence ||
        product_name_from_snapshots(manifest).presence
    end
    private_class_method :manifest_product_name

    def product_name_from_snapshots(manifest)
      snapshots = manifest.recording_snapshots
      return unless snapshots.is_a?(Hash)

      snapshots.each_value do |snapshot|
        next unless snapshot.is_a?(Hash)

        type = snapshot["recordable_type"] || snapshot[:recordable_type]
        next unless type.to_s == "RecordingStudioBilling::Product"

        attributes = snapshot["attributes"] || snapshot[:attributes] || snapshot
        name = attributes["name"] || attributes[:name]
        return name if name.present?
      end
      nil
    end
    private_class_method :product_name_from_snapshots

    def subscription_label(subscription)
      plan_name = subscription_plan_name(subscription)
      return plan_name if plan_name.present?

      account = subscription.account_recording&.recordable
      account.try(:name).presence || workspace_name_for(subscription).presence
    end
    private_class_method :subscription_label

    def subscription_plan_name(subscription)
      lines = if subscription.respond_to?(:active_lines)
                subscription.active_lines.to_a
              else
                Array(subscription.try(:lines))
              end
      plan_line = lines.find do |line|
        product = line.product_recording&.recordable
        product.respond_to?(:kind) && product.kind.to_s == "plan"
      end || lines.first
      commercial_product_name(plan_line&.billing_option_recording&.recordable) ||
        plan_line&.product_recording&.recordable.try(:name)
    end
    private_class_method :subscription_plan_name

    def plan_update_label(plan_update)
      name = commercial_product_name(plan_update.billing_option_recording&.recordable)
      return name if name.present?

      humanize_plan_update_key(plan_update.key)
    end
    private_class_method :plan_update_label

    def humanize_plan_update_key(key)
      stripped = key.to_s.delete_prefix("demo_").delete_prefix("plan_update_")
      DisplayFormatters.title_case_key(stripped)
    end
    private_class_method :humanize_plan_update_key

    def commercial_product_name(billing_option)
      return unless billing_option

      product = billing_option.product_recording&.recordable
      product.try(:name).presence || name_from_product_key(product.try(:key))
    end
    private_class_method :commercial_product_name

    def name_from_product_key(key)
      return if key.blank?

      Product.with_current_recording.find_by(key: key.to_s)&.name.presence ||
        RecordingStudioBilling.configuration.product_display_names[key.to_s].presence
    end
    private_class_method :name_from_product_key

    def workspace_name_for(subscription)
      root = subscription.root_recording
      root&.recordable.try(:name)
    end
    private_class_method :workspace_name_for
  end
end
