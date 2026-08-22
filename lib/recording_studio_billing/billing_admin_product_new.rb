# frozen_string_literal: true

require "recording_studio_admin"

module RecordingStudioBilling
  module BillingAdminProductNew
    SCREEN_KEY = "billing_product_new"
    RESOURCE_KEY = "billing_products"
    KIND_OPTIONS = [
      ["Plan", "plan"],
      ["Add-on", "addon"],
      ["Credit pack", "credit_pack"],
      ["Service", "service"]
    ].freeze

    module_function

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

    def create_url_for(context)
      parent_recording_id = billing_admin_recording_for(context).id
      engine_path = Engine.routes.url_helpers.admin_operations_create_path(
        operation: "create_draft_product",
        parent_recording_id:
      )
      "#{billing_mount_path(context)}#{engine_path}"
    end

    def products_screen_path(context)
      context.admin_screen_path(RESOURCE_KEY)
    end

    def new_screen_path(context)
      context.admin_screen_path(SCREEN_KEY)
    end

    def provider_options_for(context)
      billing_admin = billing_admin_recording_for(context)
      ProviderAccount.with_current_recording
                     .where(billing_admin_recording_id: billing_admin.id)
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

    def authorize_create!(context, audit: false)
      RecordingStudioAdmin.authorize_resource!(
        key: RESOURCE_KEY,
        action: :create,
        context: context,
        record: billing_admin_recording_for(context),
        audit: audit
      )
    end

    def create_allowed?(context)
      authorize_create!(context)
      true
    rescue RecordingStudioAdmin::AuthorizationFailed, RecordingStudioAdmin::DefinitionNotFound
      false
    end
  end

  class BillingProductNewScreen < RecordingStudioAdmin::Screen
    key BillingAdminProductNew::SCREEN_KEY
    title "New product"
    blast_radius :site
    query { |_context| Product.none }
  end

  module AdminProductNewAuthorization
    extend ActiveSupport::Concern

    included do
      before_action :authorize_billing_product_new!, only: :show
    end

    private

    def authorize_billing_product_new!
      return unless params[:key].to_s == BillingAdminProductNew::SCREEN_KEY

      BillingAdminProductNew.authorize_create!(recording_studio_admin_context, audit: true)
    rescue RecordingStudioAdmin::AuthorizationFailed, RecordingStudioAdmin::DefinitionNotFound
      head :forbidden
    end
  end
end
