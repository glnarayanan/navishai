class MemoryRecordsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :require_memory_inspector

  rescue_from Current::RoleAccessDenied, with: :forbidden

  def index
    relation = accessible_records
    relation = relation.where(memory_type: params[:type]) if params[:type].in?(MemoryRecord::MEMORY_TYPES)
    relation = relation.where(scope_kind: params[:scope]) if params[:scope].in?(MemoryRecord::SCOPE_KINDS)
    relation = relation.where(authority: params[:authority]) if params[:authority].in?(MemoryRecord::AUTHORITIES)
    relation = state_scope(relation, params[:state])
    @records = relation.includes(:memory_tombstone, :revisions, :memory_index_entry).order(observed_at: :desc, id: :desc).limit(100)
    @access_scope = @membership.can_manage_work? ? "all" : "used"
    @can_manage = @membership.can_manage_work?
    @pending_corrections = if @membership.can_manage_work?
      @workspace.memory_correction_proposals.proposed.includes(:memory_record, :proposed_by_user).order(created_at: :asc, id: :asc)
    else
      @workspace.memory_correction_proposals.where(proposed_by_membership: @membership)
        .includes(:memory_record).order(created_at: :desc, id: :desc).limit(20)
    end
    audit_event(
      "memory.library_inspected", subject: @workspace,
      metadata: { access_scope: @access_scope, record_count: @records.size }
    )
  end

  def show
    @memory_record = accessible_records.includes(
      :memory_tombstone, :memory_index_entry, :source_agent_profile, :source_user,
      revisions: :memory_tombstone,
      memory_correction_proposals: [ :proposed_by_user, :reviewed_by_user, :published_memory_record ]
    ).find(params[:id])
    @corrections = @memory_record.memory_correction_proposals
    @corrections = @corrections.where(proposed_by_membership: @membership) unless @membership.can_manage_work?
    @corrections = @corrections.order(created_at: :desc, id: :desc)
    @can_manage = @membership.can_manage_work?
    @correctable = @memory_record.memory_tombstone.nil? && @memory_record.revisions.empty?
    audit_event("memory.record_inspected", subject: @memory_record)
  end

  def destroy
    memory = @workspace.memory_records.find(params[:id])
    MemoryGovernance.delete!(
      workspace: @workspace, membership: @membership, memory_record: memory,
      reason: params.require(:reason)
    )
    redirect_to workspace_memory_record_path(@workspace, memory), notice: "Memory removed from current use."
  rescue MemoryGovernance::Conflict, ActiveRecord::RecordInvalid, ActionController::ParameterMissing => error
    redirect_to workspace_memory_record_path(@workspace, params[:id]), alert: error.message
  end

  def retry_removal
    memory = @workspace.memory_records.find(params[:id])
    raise ActiveRecord::RecordNotFound unless memory.memory_tombstone

    MemoryGovernance.retry_deletion!(
      workspace: @workspace, membership: @membership, tombstone: memory.memory_tombstone
    )
    redirect_to workspace_memory_record_path(@workspace, memory), notice: "Index removal queued again."
  rescue MemoryGovernance::Conflict => error
    redirect_to workspace_memory_record_path(@workspace, params[:id]), alert: error.message
  end

  private
    def require_memory_inspector
      @workspace = Current.require_workspace!
      @membership = Current.require_membership!
      head :forbidden unless @membership.can_inspect_memory?
    end

    def accessible_records
      MemoryGovernance.accessible_records(@workspace, @membership)
    end

    def state_scope(relation, state)
      case state
      when "current" then relation.current.available
      when "superseded" then relation.where.associated(:revisions).available
      when "deleted" then relation.where.associated(:memory_tombstone)
      else relation
      end
    end

    def forbidden
      head :forbidden
    end
end
