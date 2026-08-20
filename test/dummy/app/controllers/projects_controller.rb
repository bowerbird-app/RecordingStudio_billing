# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :require_current_root_recording!

  def index
    @projects = Project.for_root(current_root_recording).order(:created_at)
    @gate_status = RecordingStudioBilling.gate_status(
      root_recording: current_root_recording,
      gate_key: "demo_projects"
    )
  end

  def create
    RecordingStudioBilling.require_gate!(
      root_recording: current_root_recording,
      gate_key: "demo_projects"
    )
    current_root_recording.record(Project) do |project|
      project.name = project_params.fetch(:name)
    end
    redirect_to projects_path, notice: "Project ready."
  rescue RecordingStudioBilling::EnforceGate::Denied => e
    redirect_to projects_path, alert: RecordingStudioBilling.gate_message(e)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to projects_path, alert: e.record.errors.full_messages.to_sentence
  end

  private

  def require_current_root_recording!
    return if current_root_recording.present?

    redirect_to root_path, alert: "Pick a workspace first."
  end

  def project_params
    params.require(:project).permit(:name)
  end
end
