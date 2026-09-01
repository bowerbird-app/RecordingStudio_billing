# frozen_string_literal: true

module RecordingStudioBilling
  class AdminPageController < ApplicationController
    # Subclasses that authorize against an Admin root skip the customer Account loader themselves.
  end
end
