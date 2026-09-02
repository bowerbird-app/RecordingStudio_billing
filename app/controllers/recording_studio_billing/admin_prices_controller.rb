# frozen_string_literal: true

module RecordingStudioBilling
  class AdminPricesController < AdminPageController
    def new
      render_billing_admin_page(:price_new)
    end

    def edit
      render_billing_admin_page(:price_edit)
    end
  end
end
