# frozen_string_literal: true

module RecordingStudioBilling
  class AdminOptionsController < AdminPageController
    def new
      render_billing_admin_page(:billing_option_new)
    end

    def edit
      render_billing_admin_page(:billing_option_edit)
    end
  end
end
