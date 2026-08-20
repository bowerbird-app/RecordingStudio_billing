# frozen_string_literal: true

module RecordingStudioBilling
  class GateStatus
    Result = Data.define(
      :allowed, :gate_key, :current, :limit, :remaining, :unlimited, :code, :reason, :message, :quantity,
      :upgrade_path
    )

    def self.call(...) = new(...).call

    def initialize(root_recording:, gate_key:, subject: nil, quantity: 1)
      @root_recording = root_recording
      @gate_key = gate_key
      @subject = subject
      @quantity = quantity
    end

    def call
      result = EnforceGate.call(root_recording:, gate_key:, subject:, quantity:)
      Result.new(
        allowed: result.allowed,
        gate_key: result.gate_key,
        current: result.current,
        limit: result.limit,
        remaining: result.remaining,
        unlimited: unlimited?(result.limit),
        code: result.code,
        reason: result.reason,
        message: GateMessage.call(result),
        quantity: result.quantity,
        upgrade_path: result.allowed ? nil : PlansPage.path_for(root_recording)
      )
    end

    private

    attr_reader :gate_key, :quantity, :root_recording, :subject

    def unlimited?(limit)
      limit == EnforceGate::UNLIMITED
    end
  end
end
