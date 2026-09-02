# frozen_string_literal: true

module RecordingStudioBilling
  class AdminProductsController < AdminPageController
    def new
      render_billing_admin_page(:product_new)
    end

    def edit
      render_billing_admin_page(:product_edit)
    end
  end
end
