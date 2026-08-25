class SupportCaseCommandsController < SupportCasesController
  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from CaseWorkflow::InvalidTransition, ActiveRecord::RecordInvalid, ArgumentError, with: :invalid_change

  def transition
    CaseWorkflow.transition!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      to: params[:status],
      reason: params[:reason]
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case), notice: "Case status updated."
  end

  def assignment
    assignee = Current.workspace.memberships.find(params[:assigned_membership_id]) if params[:assigned_membership_id].present?
    CaseWorkflow.assign!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      assignee: assignee
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case), notice: "Assignment updated."
  end

  def priority
    CaseWorkflow.prioritize!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      priority: params[:priority]
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case), notice: "Priority updated."
  end

  def tag
    selected_tag = Current.workspace.tags.find(params[:tag_id])
    CaseWorkflow.tag!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      tag: selected_tag
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case), notice: "Tag added."
  end

  def untag
    selected_tag = Current.workspace.tags.find(params[:tag_id])
    CaseWorkflow.untag!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      tag: selected_tag
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case), notice: "Tag removed."
  end

  def add_note
    CaseWorkflow.add_note!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      body: params[:body]
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: "notes"), notice: "Private note added."
  end

  def create_tag
    Tag.transaction do
      tag = CaseWorkflow.create_tag!(
        workspace: Current.workspace,
        membership: Current.require_membership!,
        name: params[:name]
      )
      CaseWorkflow.tag!(
        workspace: Current.workspace,
        support_case: @support_case,
        membership: Current.require_membership!,
        tag: tag
      )
    end
    redirect_to workspace_support_case_path(Current.workspace, @support_case), notice: "Tag created and added."
  end

  private
    def forbidden
      render "shared/permission_denied", status: :forbidden
    end

    def invalid_change(error)
      @command_error = error.message
      @submitted_status = params[:status]
      @submitted_reason = params[:reason]
      @submitted_priority = params[:priority]
      @submitted_assignee_id = params[:assigned_membership_id]
      @submitted_tag_id = params[:tag_id]
      @submitted_note = params[:body]
      @submitted_tag_name = params[:name]
      load_workspace
      render "support_cases/show", status: :unprocessable_content
    end
end
