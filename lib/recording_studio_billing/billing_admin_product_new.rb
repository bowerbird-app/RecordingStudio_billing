# frozen_string_literal: true

require "recording_studio_admin"
require "recording_studio_billing/billing_admin_forms"

module RecordingStudioBilling
  module BillingAdminProductNew
    RESOURCE_KEY = "billing_products"
    KIND_OPTIONS = BillingAdminForms::KIND_OPTIONS
    Scope = BillingAdminForms::Scope
    Page = BillingAdminForms::Page

    module_function

    def scope!(parent_recording_id:)
      BillingAdminForms.scope!(parent_recording_id:)
    end

    def page!(scope:, context:, return_to:)
      BillingAdminForms.page!(
        page_key: :product_new,
        scope: scope,
        context: context,
        return_to: return_to
      )
    end

    def billing_admin_recording_for(context)
      BillingAdminForms.billing_admin_recording_for(context)
    end

    def create_url_for(context)
      BillingAdminForms.create_url_for(:product, context)
    end

    def new_url_for(context, kind: nil)
      BillingAdminForms.new_url_for(:product, context, kind:)
    end

    def edit_url_for(record, context)
      BillingAdminForms.edit_url_for(:product, record, context)
    end

    def new_option_url_for(context)
      BillingAdminForms.new_url_for(:billing_option, context)
    end

    def edit_option_url_for(record, context)
      BillingAdminForms.edit_url_for(:billing_option, record, context)
    end

    def new_price_url_for(context)
      BillingAdminForms.new_url_for(:price, context)
    end

    def edit_price_url_for(record, context)
      BillingAdminForms.edit_url_for(:price, record, context)
    end

    def mounted_operation_url(context, engine_path)
      BillingAdminForms.mounted_operation_url(context, engine_path)
    end

    def products_screen_path(context)
      context.admin_screen_path(RESOURCE_KEY)
    end

    def provider_options_for(billing_admin_recording)
      BillingAdminForms.provider_options_for(billing_admin_recording)
    end

    def provider_label(account)
      name = account.name.to_s.strip
      return account.key if name.blank? || name == account.key

      "#{name} (#{account.key})"
    end

    def billing_mount_path(context)
      BillingAdminForms.billing_mount_path(context)
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
      BillingAdminForms.create_allowed?(:product, context)
    end

    def create_action_visible?(record, context)
      context.params["parent_recording_id"].present? ||
        (record.is_a?(RecordingStudio::Recording) &&
         record.recordable_type == "RecordingStudioBilling::BillingAdmin")
    end

    def sanitized_return_path(return_to, context)
      safe_return = RecordingStudioAdmin::UrlSafety.safe_href(return_to)
      return products_screen_path(context) if safe_return.blank? || safe_return == "#"

      safe_return
    end
    private_class_method :sanitized_return_path
  end
end
