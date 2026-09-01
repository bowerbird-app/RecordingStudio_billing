# frozen_string_literal: true

module RecordingStudioBilling
  class AdminPageController < ApplicationController
    skip_before_action :load_root_recording!
  end
end
