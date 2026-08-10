# frozen_string_literal: true

module RecordingStudioBilling
  # The engine's model base keeps host application models out of the engine
  # namespace while retaining the normal Active Record public API.
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
