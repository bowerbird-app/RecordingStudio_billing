# frozen_string_literal: true

module RecordingStudioBilling
  MeterCredits = Data.define(:meter_key, :included, :purchased, :used, :remaining)
end
