class KnowledgeImprovementCandidatesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :set_context
  before_action :set_candidate, except: :create

  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from KnowledgeImprovementWorkflow::InvalidCommand, with: :invalid_change

  def create
    if params[:crew_artifact_id].present?
      artifact = @workspace.crew_artifacts.find(params.require(:crew_artifact_id))
      KnowledgeImprovementWorkflow.create_from_blocked_draft!(
        workspace: @workspace, membership: @membership, artifact:
      )
      redirect_to return_path, notice: "Knowledge improvement candidate recorded from the blocked draft."
    else
      source = @workspace.knowledge_sources.find(params.require(:knowledge_source_id))
      KnowledgeImprovementWorkflow.create_from_source!(
        workspace: @workspace, membership: @membership, knowledge_source: source
      )
      redirect_to workspace_knowledge_improvements_path(@workspace),
        notice: "Knowledge improvement candidate recorded for a human owner."
    end
  end

  def triage
    KnowledgeImprovementWorkflow.triage!(
      workspace: @workspace, membership: @membership, candidate: @candidate, note: params[:note]
    )
    redirect_to workspace_knowledge_improvements_path(@workspace),
      notice: "Candidate triaged without changing knowledge or sending a message."
  end

  def assign
    assignee = @workspace.memberships.find(params.require(:assigned_to_membership_id))
    KnowledgeImprovementWorkflow.assign!(
      workspace: @workspace, membership: @membership, candidate: @candidate, assignee:
    )
    redirect_to workspace_knowledge_improvements_path(@workspace),
      notice: "Candidate assigned to a human who can maintain knowledge."
  end

  def resolve
    source = @workspace.knowledge_sources.find(params.require(:knowledge_source_id))
    KnowledgeImprovementWorkflow.resolve!(
      workspace: @workspace, membership: @membership, candidate: @candidate, knowledge_source: source
    )
    redirect_to workspace_knowledge_improvements_path(@workspace),
      notice: "Candidate resolved against a current authorised knowledge version."
  end

  def dismiss
    KnowledgeImprovementWorkflow.dismiss!(
      workspace: @workspace, membership: @membership, candidate: @candidate, reason: params[:reason]
    )
    redirect_to workspace_knowledge_improvements_path(@workspace),
      notice: "Candidate dismissed with a recorded human reason."
  end

  private
    def set_context
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
    end

    def set_candidate
      @candidate = @workspace.knowledge_improvement_candidates.find(params[:id])
    end

    def return_path
      if params[:return_to] == "quality"
        workspace_support_quality_path(@workspace)
      else
        workspace_knowledge_improvements_path(@workspace)
      end
    end

    def invalid_change(error)
      redirect_to return_path, alert: error.message
    end
end
