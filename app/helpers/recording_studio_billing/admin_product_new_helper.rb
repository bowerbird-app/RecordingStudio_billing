# frozen_string_literal: true

module RecordingStudioBilling
  module AdminProductNewHelper
    def billing_admin_product_new_create_url
      BillingAdminProductNew.create_url_for(recording_studio_admin_context)
    end

    def billing_admin_product_new_cancel_url
      BillingAdminProductNew.products_screen_path(recording_studio_admin_context)
    end

    def billing_admin_product_new_parent_recording_id
      BillingAdminProductNew.billing_admin_recording_for(recording_studio_admin_context).id
    end

    def billing_admin_product_kind_options
      BillingAdminProductNew::KIND_OPTIONS
    end

    def billing_admin_product_provider_options
      BillingAdminProductNew.provider_options_for(recording_studio_admin_context)
    end
  end
end
