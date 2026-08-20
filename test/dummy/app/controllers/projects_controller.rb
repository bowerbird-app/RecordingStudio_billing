# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :require_workspace_root!
  helper_method :workspace_root_id

  def index
    @projects = Project.for_root(workspace_root).order(:created_at)
    @gate_status = RecordingStudioBilling.gate_status(
      root_recording: workspace_root,
      gate_key: "demo_projects"
    )
  end

  def create
    RecordingStudioBilling.require_gate!(
      root_recording: workspace_root,
      gate_key: "demo_projects"
    )
    workspace_root.record(Project) do |project|
      project.name = project_params.fetch(:name)
    end
    redirect_to projects_path(root_recording_id: workspace_root.id), notice: "Project ready."
  rescue RecordingStudioBilling::EnforceGate::Denied => e
    redirect_to projects_path(root_recording_id: workspace_root.id),
                alert: RecordingStudioBilling.gate_message(e)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to projects_path(root_recording_id: workspace_root.id),
                alert: e.record.errors.full_messages.to_sentence
  end

  private

  def workspace_root
    @workspace_root ||= begin
      if params[:root_recording_id].present?
        RecordingStudio::Recording.find(params[:root_recording_id])
      else
        current_root_recording
      end
    end
  end

  def workspace_root_id
    workspace_root&.id
  end

  def require_workspace_root!
    return if workspace_root.present?

    redirect_to root_path, alert: "Pick a workspace first."
  end

  def project_params
    params.require(:project).permit(:name)
  end
end
