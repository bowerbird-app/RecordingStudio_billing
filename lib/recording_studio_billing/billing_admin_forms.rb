# frozen_string_literal: true

require "recording_studio_admin"

module RecordingStudioBilling
  module BillingAdminForms
    KIND_SCREENS = {
      "billing_plans" => { title: "Plans", kind: "plan" },
      "billing_addons" => { title: "Add-ons", kind: "addon" }
    }.freeze

    PAGES = {
      product_new: {
        resource: :product, resource_key: "billing_products", model: "Product", mode: :new,
        route: :new_admin_product_path, operation: "create_draft_product", title: "New product",
        surface: "billing_admin_product_new", fixed_parent: true, options: %i[provider]
      },
      product_edit: {
        resource: :product, resource_key: "billing_products", model: "Product", mode: :edit,
        route: :edit_admin_product_path, operation: "revise_product", title: "Edit product",
        surface: "billing_admin_product_edit", options: %i[provider]
      },
      billing_option_new: {
        resource: :billing_option, resource_key: "billing_options", model: "BillingOption", mode: :new,
        route: :new_admin_option_path, operation: "create_draft_billing_option", title: "New billing option",
        surface: "billing_admin_option_new", options: %i[product]
      },
      billing_option_edit: {
        resource: :billing_option, resource_key: "billing_options", model: "BillingOption", mode: :edit,
        route: :edit_admin_option_path, operation: "revise_billing_option", title: "Edit billing option",
        surface: "billing_admin_option_edit", options: []
      },
      price_new: {
        resource: :price, resource_key: "billing_prices", model: "Price", mode: :new,
        route: :new_admin_price_path, operation: "create_draft_price", title: "New price",
        surface: "billing_admin_price_new", options: %i[billing_option market]
      },
      price_edit: {
        resource: :price, resource_key: "billing_prices", model: "Price", mode: :edit,
        route: :edit_admin_price_path, operation: "revise_price", title: "Edit price",
        surface: "billing_admin_price_edit", options: %i[market]
      }
    }.freeze

    KIND_TITLES = {
      "plan" => "New plan",
      "addon" => "New add-on"
    }.freeze

    KIND_OPTIONS = [
      ["Plan", "plan"],
      ["Add-on", "addon"],
      ["Credit pack", "credit_pack"],
      ["Service", "service"]
    ].freeze

    Scope = Data.define(:access_recording, :billing_admin_recording, :record)

    Page = Data.define(
      :key, :title, :access_recording, :billing_admin_recording, :record,
      :submit_path, :cancel_path, :parent_recording_id, :kind, :kind_locked,
      :kind_options, :provider_options, :product_options, :billing_option_options, :market_options
    ) do
      def create_path = submit_path

      def value(attribute)
        record&.public_send(attribute)
      end

      def kind_locked? = kind_locked
    end

    module_function

    def definition_for(page_key)
      PAGES.fetch(page_key.to_sym)
    end

    def page_key_for(resource, mode)
      normalized_resource = {
        "billing_products" => :product,
        "billing_options" => :billing_option,
        "billing_prices" => :price
      }.fetch(resource.to_s, resource.to_sym)
      PAGES.find do |_key, definition|
        definition.fetch(:resource) == normalized_resource && definition.fetch(:mode) == mode.to_sym
      end&.first || raise(KeyError, "unknown billing admin form #{resource} #{mode}")
    end

    def scope!(parent_recording_id:)
      raise ActiveRecord::RecordNotFound if parent_recording_id.blank?

      billing_admin = RecordingStudio::Recording.unscoped.find_by!(
        id: parent_recording_id,
        recordable_type: "RecordingStudioBilling::BillingAdmin",
        trashed_at: nil
      )
      raise ActiveRecord::RecordNotFound unless billing_admin.parent_recording_id == billing_admin.root_recording_id
      raise ActiveRecord::RecordNotFound if billing_admin.root_recording_id.blank?

      access_recording = RecordingStudio::Recording.unscoped.find_by!(
        id: billing_admin.root_recording_id,
        trashed_at: nil
      )
      raise ActiveRecord::RecordNotFound unless access_recording.id == access_recording.root_recording_id

      Scope.new(access_recording:, billing_admin_recording: billing_admin, record: nil)
    end

    def scope_for!(page_key:, parent_recording_id: nil, id: nil)
      definition = definition_for(page_key)
      return scope!(parent_recording_id:) if definition.fetch(:mode) == :new

      edit_scope!(definition, id)
    end

    def page!(page_key:, scope:, context:, return_to:)
      definition = definition_for(page_key)
      action = definition.fetch(:mode) == :new ? :create : :edit
      authorization_record = scope.record || scope.billing_admin_recording
      authorize!(definition, context, action, authorization_record, audit: true)

      kind = locked_kind(definition, context)
      record = scope.record || new_record(definition, kind)
      options = option_sets_for(definition, scope.billing_admin_recording)
      Page.new(
        key: page_key.to_sym,
        title: kind ? KIND_TITLES.fetch(kind, definition.fetch(:title)) : definition.fetch(:title),
        access_recording: scope.access_recording,
        billing_admin_recording: scope.billing_admin_recording,
        record: record,
        submit_path: submit_url_for(definition, scope, context),
        cancel_path: sanitized_return_path(return_to, context, definition.fetch(:resource_key)),
        parent_recording_id: definition[:fixed_parent] ? scope.billing_admin_recording.id : nil,
        kind: kind,
        kind_locked: kind.present?,
        kind_options: KIND_OPTIONS,
        provider_options: options.fetch(:provider, []),
        product_options: options.fetch(:product, []),
        billing_option_options: options.fetch(:billing_option, []),
        market_options: options.fetch(:market, [])
      )
    end

    def new_url_for(resource, context, kind: nil)
      definition = definition_for(page_key_for(resource, :new))
      billing_admin = billing_admin_recording_for(context)
      return_screen = kind_screen_key(kind) || definition.fetch(:resource_key)
      arguments = {
        parent_recording_id: billing_admin.id,
        return_to: context.admin_screen_path(return_screen)
      }
      arguments[:kind] = kind if kind.present?
      mounted_operation_url(context, Engine.routes.url_helpers.public_send(definition.fetch(:route), **arguments))
    end

    def edit_url_for(resource, record, context)
      definition = definition_for(page_key_for(resource, :edit))
      return_screen = current_inventory_screen(context, definition.fetch(:resource_key))
      engine_path = Engine.routes.url_helpers.public_send(
        definition.fetch(:route),
        record.id,
        return_to: context.admin_screen_path(return_screen)
      )
      mounted_operation_url(context, engine_path)
    end

    def create_url_for(resource, context)
      definition = definition_for(page_key_for(resource, :new))
      billing_admin = billing_admin_recording_for(context)
      engine_path = Engine.routes.url_helpers.admin_operations_create_path(
        operation: definition.fetch(:operation),
        parent_recording_id: (billing_admin.id if definition[:fixed_parent])
      )
      mounted_operation_url(context, engine_path)
    end

    def create_allowed?(resource, context)
      definition = definition_for(page_key_for(resource, :new))
      authorize!(definition, context, :create, billing_admin_recording_for(context))
      true
    rescue RecordingStudioAdmin::AuthorizationFailed, RecordingStudioAdmin::DefinitionNotFound
      false
    end

    def billing_admin_recording_for(context)
      root = context.access_recording
      raise RecordingStudioAdmin::DefinitionNotFound, "Admin root is missing" if root.blank?

      RecordingStudio::Recording.unscoped.find_by!(
        root_recording_id: root.id,
        parent_recording_id: root.id,
        recordable_type: "RecordingStudioBilling::BillingAdmin",
        trashed_at: nil
      )
    rescue ActiveRecord::RecordNotFound
      raise RecordingStudioAdmin::DefinitionNotFound, "Billing admin is missing"
    end

    def provider_options_for(billing_admin_recording)
      ProviderAccount.with_current_recording
                     .where(billing_admin_recording_id: billing_admin_recording.id)
                     .order(:name, :key)
                     .map { |account| [label_with_key(account), account.recording.id] }
    end

    def product_options_for(billing_admin_recording)
      product_scope(billing_admin_recording).order(:name, :key)
                                            .map { |product| [label_with_key(product), product.recording.id] }
    end

    def billing_option_options_for(billing_admin_recording)
      products = product_scope(billing_admin_recording).index_by { |product| product.recording.id }
      option_scope(billing_admin_recording).order(:name, :key).map do |option|
        product = products.fetch(option.product_recording_id)
        ["#{label_with_key(product)} · #{label_with_key(option)}", option.recording.id]
      end
    end

    def market_options_for(billing_admin_recording)
      market_scope(billing_admin_recording).order(:key).map { |market| [market.key, market.recording.id] }
    end

    def mounted_operation_url(context, engine_path)
      mount = billing_mount_path(context)
      return engine_path if mount.blank? || engine_path.start_with?(mount)

      "#{mount}#{engine_path}"
    end

    def billing_mount_path(context)
      if context.controller.respond_to?(:main_app)
        context.controller.main_app.recording_studio_billing_path
      else
        "/billing"
      end.to_s.chomp("/")
    end

    def kind_screen_classes
      @kind_screen_classes ||= KIND_SCREENS.map do |screen_key, specification|
        build_kind_screen(screen_key, specification)
      end.freeze
    end

    def kind_screen_title(screen_key)
      KIND_SCREENS.fetch(screen_key.to_s).fetch(:title)
    end

    def product_scope(billing_admin_recording)
      recordings = direct_recordings_for(Product, billing_admin_recording)
      Product.with_current_recording.where(id: recordings.select(:recordable_id))
    end

    def option_scope(billing_admin_recording)
      product_recordings = direct_recordings_for(Product, billing_admin_recording)
      BillingOption.with_current_recording.where(product_recording_id: product_recordings.select(:id))
    end

    def market_scope(billing_admin_recording)
      recordings = direct_recordings_for(Market, billing_admin_recording)
      Market.with_current_recording.where(id: recordings.select(:recordable_id))
    end

    def edit_scope!(definition, id)
      model = "RecordingStudioBilling::#{definition.fetch(:model)}".constantize
      record = model.with_current_recording.find(id)
      billing_admin = billing_admin_ancestor!(record.recording)
      base_scope = scope!(parent_recording_id: billing_admin.id)
      relation = scoped_relation_for(model, billing_admin)
      raise ActiveRecord::RecordNotFound unless relation.where(id: record.id).exists?

      Scope.new(
        access_recording: base_scope.access_recording,
        billing_admin_recording: billing_admin,
        record: record
      )
    end
    private_class_method :edit_scope!

    def scoped_relation_for(model, billing_admin)
      return product_scope(billing_admin) if model == Product
      return option_scope(billing_admin) if model == BillingOption

      option_recordings = RecordingStudio::Recording.unscoped.where(
        recordable_type: BillingOption.name,
        recordable_id: option_scope(billing_admin).select(:id),
        trashed_at: nil
      )
      model.with_current_recording.where(billing_option_recording_id: option_recordings.select(:id))
    end
    private_class_method :scoped_relation_for

    def direct_recordings_for(model, billing_admin_recording)
      RecordingStudio::Recording.unscoped.where(
        root_recording_id: billing_admin_recording.root_recording_id,
        parent_recording_id: billing_admin_recording.id,
        recordable_type: model.name,
        trashed_at: nil
      )
    end
    private_class_method :direct_recordings_for

    def billing_admin_ancestor!(recording)
      current = recording
      current = current.parent_recording until current.nil? || current.recordable_type == "RecordingStudioBilling::BillingAdmin"
      current || raise(ActiveRecord::RecordNotFound)
    end
    private_class_method :billing_admin_ancestor!

    def option_sets_for(definition, billing_admin_recording)
      definition.fetch(:options).to_h do |option_key|
        [option_key, public_send("#{option_key}_options_for", billing_admin_recording)]
      end
    end
    private_class_method :option_sets_for

    def submit_url_for(definition, scope, context)
      arguments = { operation: definition.fetch(:operation) }
      if definition.fetch(:mode) == :edit
        engine_path = Engine.routes.url_helpers.admin_operation_path(**arguments, id: scope.record.id)
      else
        arguments[:parent_recording_id] = scope.billing_admin_recording.id if definition[:fixed_parent]
        engine_path = Engine.routes.url_helpers.admin_operations_create_path(**arguments)
      end
      mounted_operation_url(context, engine_path)
    end
    private_class_method :submit_url_for

    def new_record(definition, kind)
      model = "RecordingStudioBilling::#{definition.fetch(:model)}".constantize
      attributes = {}
      attributes[:kind] = kind if kind
      attributes.merge!(pricing_model: "flat", currency_exponent: 2, version: 1, scope: "market") if model == Price
      model.new(attributes)
    end
    private_class_method :new_record

    def locked_kind(definition, context)
      return unless definition.fetch(:resource) == :product && definition.fetch(:mode) == :new

      kind = context.params["kind"].presence
      return if kind.blank?
      raise ActiveRecord::RecordNotFound unless Product::KINDS.include?(kind)

      kind
    end
    private_class_method :locked_kind

    def authorize!(definition, context, action, record, audit: false)
      RecordingStudioAdmin.authorize_resource!(
        key: definition.fetch(:resource_key),
        action: action,
        context: context,
        record: record,
        audit: audit
      )
    end
    private_class_method :authorize!

    def sanitized_return_path(return_to, context, resource_key)
      safe_return = RecordingStudioAdmin::UrlSafety.safe_href(return_to)
      return context.admin_screen_path(resource_key) if safe_return.blank? || safe_return == "#"

      safe_return
    end
    private_class_method :sanitized_return_path

    def label_with_key(record)
      name = record.respond_to?(:name) ? record.name.to_s.strip : ""
      return record.key if name.blank? || name == record.key

      "#{name} (#{record.key})"
    end
    private_class_method :label_with_key

    def kind_screen_key(kind)
      KIND_SCREENS.find { |_key, specification| specification.fetch(:kind) == kind }&.first
    end
    private_class_method :kind_screen_key

    def current_inventory_screen(context, default)
      key = context.params["key"].to_s
      return key if key == default || KIND_SCREENS.key?(key)

      default
    end
    private_class_method :current_inventory_screen

    def build_kind_screen(screen_key, specification)
      Class.new(RecordingStudioAdmin::Screen) do
        key screen_key
        title specification.fetch(:title)
        blast_radius :site
        query do |_context|
          Product.with_current_recording.where(kind: specification.fetch(:kind)).order(created_at: :desc)
        end
        filter :key, **BillingAdminHubs.inventory_filter_options(:key)
        filter :state, label: "State"
        button :new_product,
               text: "New",
               style: :primary,
               url: ->(context) { BillingAdminForms.new_url_for(:product, context, kind: specification.fetch(:kind)) },
               visible_if: ->(context) { BillingAdminForms.create_allowed?(:product, context) }
        table do
          title specification.fetch(:title)
          %i[name key kind state].each { |column_key| column column_key }
          default_columns :name, :key, :kind, :state
          default_sort :created_at, direction: :desc
          admin_action :billing_products, :edit
          admin_action :billing_products, :retire
        end
      end
    end
    private_class_method :build_kind_screen
  end
end
