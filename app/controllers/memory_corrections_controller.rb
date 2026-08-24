class MemoryCorrectionsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace

  rescue_from Current::RoleAccessDenied, with: :forbidden

  def create
    workspace = Current.require_workspace!
    membership = Current.require_membership!
    memory = workspace.memory_records.find(params[:memory_record_id])
    proposal = MemoryGovernance.propose_correction!(
      workspace:, membership:, memory_record: memory, **correction_params.to_h.symbolize_keys
    )
    notice = proposal.accepted? ? "Correction published." : "Correction sent for review."
    redirect_to workspace_memory_record_path(workspace, memory), notice:
  rescue MemoryGovernance::Conflict, ActiveRecord::RecordInvalid => error
    redirect_to workspace_memory_record_path(Current.workspace, params[:memory_record_id]), alert: error.message
  end

  def review
    workspace = Current.require_workspace!
    proposal = workspace.memory_correction_proposals.find(params[:correction_id])
    MemoryGovernance.review_correction!(
      workspace:, membership: Current.require_membership!, proposal:, outcome: params[:outcome]
    )
    redirect_to workspace_memory_record_path(workspace, proposal.memory_record),
      notice: "Correction #{params[:outcome]}."
  rescue MemoryGovernance::Conflict, ActiveRecord::RecordInvalid, ArgumentError => error
    redirect_to workspace_memory_record_path(Current.workspace, params[:memory_record_id]), alert: error.message
  end

  private
    def correction_params
      params.expect(memory_correction: [ :content, :confidence, :retention_policy, :retention_until ])
    end

    def forbidden
      head :forbidden
    end
end
