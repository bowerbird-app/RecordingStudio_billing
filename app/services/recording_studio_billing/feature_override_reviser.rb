# frozen_string_literal: true

module RecordingStudioBilling
  class FeatureOverrideReviser
    ALLOWED_ATTRIBUTES = %i[state value].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(recording:, actor:, attributes:)
      @recording = recording
      @actor = actor
      @attributes = attributes.to_h.symbolize_keys
    end

    def call
      validate_arguments!
      RecordingStudio::Recording.transaction do
        current = RecordingStudio::Recording.unscoped.lock.find(recording.id)
        root = RecordingStudio::Recording.unscoped.lock.find(current.root_recording_id)
        authorize!(root)
        connection = ActiveRecord::Base.connection
        connection.execute("SET LOCAL recording_studio_billing.authorized_feature_override = 'on'")
        constraint = connection.quote_column_name(
          "#{FeatureOverride.table_name}_validate_publication"
        )
        connection.execute("SET CONSTRAINTS #{constraint} DEFERRED")
        root.revise(current, actor:) { |revision| revision.assign_attributes(attributes) }
      end
    end

    private

    attr_reader :recording, :actor, :attributes

    def validate_arguments!
      raise ArgumentError, "feature override revision requires a FeatureOverride recording" unless recording.is_a?(RecordingStudio::Recording) && recording.recordable.is_a?(FeatureOverride)
      raise ArgumentError, "feature override revision requires attributes" if attributes.empty?

      unknown = attributes.keys - ALLOWED_ATTRIBUTES
      raise ArgumentError, "unsupported feature override attributes: #{unknown.join(', ')}" if unknown.any?
      return if actor.respond_to?(:persisted?) && actor.persisted?

      raise ArgumentError, "feature override revision actor must be persisted"
    end

    def authorize!(root)
      authorizer = RecordingStudioBilling.configuration.commercial_authorizer
      raise ArgumentError, "feature override revision requires an authorizer" unless authorizer
      return if authorizer.call(action: :revise_feature_override, actor:, root_recording: root, candidate: nil)

      raise ArgumentError, "feature override revision is not authorized"
    end
  end
end
