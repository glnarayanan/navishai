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
    operation = nil
    IntercomSyncOperation.transaction do
      CaseWorkflow.assign!(
        workspace: Current.workspace,
        support_case: @support_case,
        membership: Current.require_membership!,
        assignee: assignee
      ) do |changed_case|
        operation = IntercomOutboundSync.enqueue!(
          workspace: Current.workspace, support_case: changed_case,
          membership: Current.require_membership!, operation_kind: :assign,
          payload: { email: assignee&.user&.email_address }
        )
      end
    end
    redirect_after_sync(operation, "Assignment updated.")
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
    operation = nil
    IntercomSyncOperation.transaction do
      CaseWorkflow.tag!(
        workspace: Current.workspace,
        support_case: @support_case,
        membership: Current.require_membership!,
        tag: selected_tag
      ) { operation = enqueue_tag_sync(:tag, selected_tag) }
    end
    redirect_after_sync(operation, "Tag added.")
  end

  def untag
    selected_tag = Current.workspace.tags.find(params[:tag_id])
    operation = nil
    IntercomSyncOperation.transaction do
      CaseWorkflow.untag!(
        workspace: Current.workspace,
        support_case: @support_case,
        membership: Current.require_membership!,
        tag: selected_tag
      ) { operation = enqueue_tag_sync(:untag, selected_tag) }
    end
    redirect_after_sync(operation, "Tag removed.")
  end

  def add_note
    operation = IntercomSyncOperation.transaction do
      note = CaseWorkflow.add_note!(
        workspace: Current.workspace,
        support_case: @support_case,
        membership: Current.require_membership!,
        body: params[:body]
      )
      IntercomOutboundSync.enqueue!(
        workspace: Current.workspace, support_case: @support_case,
        membership: Current.require_membership!, operation_kind: :note,
        payload: { body: note.body }
      )
    end
    redirect_after_sync(operation, "Private note added.", anchor: "notes")
  end

  def create_tag
    operation = nil
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
      ) { operation = enqueue_tag_sync(:tag, tag) }
    end
    redirect_after_sync(operation, "Tag created and added.")
  end

  private
    def enqueue_tag_sync(kind, tag)
      IntercomOutboundSync.enqueue!(
        workspace: Current.workspace, support_case: @support_case,
        membership: Current.require_membership!, operation_kind: kind,
        payload: { tag_id: tag.id, name: tag.name }
      )
    end

    def redirect_after_sync(operation, notice, anchor: nil)
      result = IntercomOutboundSync.deliver!(operation)
      path = workspace_support_case_path(Current.workspace, @support_case, anchor: anchor)
      if result && !result.completed?
        redirect_to path, alert: "#{notice} Intercom sync needs review."
      else
        redirect_to path, notice: notice
      end
    end

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
