# frozen_string_literal: true

class DocsController < ApplicationController
  def install
  end

  def configuration
    render :config
  end

  def recordable_types
    RecordingStudio.validate_recordable_declarations!

    @recordable_types = RecordingStudio.recordable_declarations.values.sort_by(&:type).map do |declaration|
      normalize_recordable_declaration(declaration)
    end
  end

  def recordings_tree
    recordings = RecordingStudio::Recording.includes(:recordable).reorder(:created_at, :id).to_a
    recordings_by_parent_id = recordings.group_by(&:parent_recording_id)

    @recording_tree = recordings_by_parent_id.fetch(nil, []).map do |recording|
      build_recording_node(recording, recordings_by_parent_id)
    end
  end

  def gem_views
    prefix = "#{GemTemplate::Engine.root}/"

    @engine_views = Dir.glob(GemTemplate::Engine.root.join("app/views/gem_template/**/*.erb").to_s)
      .sort
      .map { |path| path.delete_prefix(prefix) }
  end

  def methods
  end

  private

  def normalize_recordable_declaration(declaration)
    {
      name: declaration.type,
      label: declaration.label,
      root: declaration.root?,
      allowed_parent_types: RecordingStudio.allowed_parent_types_for(declaration.type),
      recordings_count: RecordingStudio::Recording.where(recordable_type: declaration.type).count,
      recordables_count: count_recordables_for(declaration.type)
    }
  end

  def count_recordables_for(type_name)
    recordable_class = type_name.safe_constantize
    return 0 unless recordable_class&.<= ActiveRecord::Base
    return 0 unless recordable_class.table_exists?

    recordable_class.count
  rescue ActiveRecord::ActiveRecordError
    0
  end

  def build_recording_node(recording, recordings_by_parent_id)
    {
      label: recording_label(recording),
      children: recordings_by_parent_id.fetch(recording.id, []).map do |child_recording|
        build_recording_node(child_recording, recordings_by_parent_id)
      end
    }
  end

  def recording_label(recording)
    type_label = recording.recordable_type.to_s.demodulize.underscore.humanize
    identifier = recordable_identifier(recording.recordable)

    "#{type_label}: #{identifier}"
  end

  def recordable_identifier(recordable)
    return "Unknown recordable" if recordable.nil?

    %i[name title email label slug identifier].each do |attribute|
      next unless recordable.respond_to?(attribute)

      value = recordable.public_send(attribute)
      return value if value.present?
    end

    actor = recordable.actor if recordable.respond_to?(:actor)
    actor_email = actor.email if actor&.respond_to?(:email) && actor.email.present?

    if recordable.respond_to?(:role) && recordable.role.present? && actor_email.present?
      return "#{recordable.role.to_s.humanize} for #{actor_email}"
    end

    return recordable.role.to_s.humanize if recordable.respond_to?(:role) && recordable.role.present?

    return recordable.minimum_role.to_s.humanize if recordable.respond_to?(:minimum_role) &&
      recordable.minimum_role.present?

    "##{recordable.id}"
  end
end
