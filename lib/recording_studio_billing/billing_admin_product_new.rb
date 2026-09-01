# frozen_string_literal: true

require "recording_studio_admin"

module RecordingStudioBilling
  module BillingAdminProductNew
    RESOURCE_KEY = "billing_products"
    KIND_OPTIONS = [
      ["Plan", "plan"],
      ["Add-on", "addon"],
      ["Credit pack", "credit_pack"],
      ["Service", "service"]
    ].freeze

    Scope = Data.define(:access_recording, :billing_admin_recording)
    Page = Data.define(
      :access_recording,
      :parent_recording_id,
      :create_path,
      :cancel_path,
      :kind_options,
      :provider_options
    )

    module_function

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

      Scope.new(access_recording:, billing_admin_recording: billing_admin)
    end

    def page!(scope:, context:, return_to:)
      authorize_create!(context, audit: true, billing_admin_recording: scope.billing_admin_recording)
      Page.new(
        access_recording: scope.access_recording,
        parent_recording_id: scope.billing_admin_recording.id,
        create_path: create_url_for(context, billing_admin_recording: scope.billing_admin_recording),
        cancel_path: sanitized_return_path(return_to, context),
        kind_options: KIND_OPTIONS,
        provider_options: provider_options_for(scope.billing_admin_recording)
      )
    end

    def billing_admin_recording_for(context)
      root = context.respond_to?(:access_recording) ? context.access_recording : nil
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

    def create_url_for(context, billing_admin_recording: nil)
      parent_recording_id = (billing_admin_recording || billing_admin_recording_for(context)).id
      engine_path = Engine.routes.url_helpers.admin_operations_create_path(
        operation: "create_draft_product",
        parent_recording_id:
      )
      mounted_operation_url(context, engine_path)
    end

    def new_url_for(context)
      engine_path = Engine.routes.url_helpers.new_admin_product_path(**new_product_query(context))
      mounted_operation_url(context, engine_path)
    end

    def mounted_operation_url(context, engine_path)
      mount = billing_mount_path(context)
      return engine_path if mount.blank? || engine_path.start_with?(mount)

      "#{mount}#{engine_path}"
    end

    def products_screen_path(context)
      context.admin_screen_path(RESOURCE_KEY)
    end

    def provider_options_for(billing_admin_recording)
      ProviderAccount.with_current_recording
                     .where(billing_admin_recording_id: billing_admin_recording.id)
                     .order(:name, :key)
                     .map { |account| [provider_label(account), account.recording.id] }
    end

    def provider_label(account)
      name = account.name.to_s.strip
      return account.key if name.blank? || name == account.key

      "#{name} (#{account.key})"
    end

    def billing_mount_path(context)
      if context.controller.respond_to?(:main_app)
        context.controller.main_app.recording_studio_billing_path
      else
        "/billing"
      end.to_s.chomp("/")
    end

    def authorize_create!(context, audit: false, billing_admin_recording: nil)
      RecordingStudioAdmin.authorize_resource!(
        key: RESOURCE_KEY,
        action: :create,
        context: context,
        record: billing_admin_recording || billing_admin_recording_for(context),
        audit: audit
      )
    end

    def create_allowed?(context)
      authorize_create!(context)
      true
    rescue RecordingStudioAdmin::AuthorizationFailed, RecordingStudioAdmin::DefinitionNotFound
      false
    end

    def create_action_visible?(record, context)
      context.params["parent_recording_id"].present? ||
        (record.is_a?(RecordingStudio::Recording) &&
         record.recordable_type == "RecordingStudioBilling::BillingAdmin")
    end

    def new_product_query(context)
      parent = billing_admin_recording_for(context)
      { parent_recording_id: parent.id, return_to: products_screen_path(context) }
    rescue RecordingStudioAdmin::DefinitionNotFound
      {}
    end
    private_class_method :new_product_query

    def sanitized_return_path(return_to, context)
      safe_return = RecordingStudioAdmin::UrlSafety.safe_href(return_to)
      return products_screen_path(context) if safe_return.blank? || safe_return == "#"

      safe_return
    end
    private_class_method :sanitized_return_path
  end
end
