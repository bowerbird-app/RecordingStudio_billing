# frozen_string_literal: true

module RecordingStudioBilling
  class ReconciliationRecord < RecordingStudioBilling::ApplicationRecord
    belongs_to :financial_command
  end
end
