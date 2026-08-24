class EmailAttachmentsController < SupportCasesController
  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError,
    AttachmentIntake::InvalidAttachment, ArgumentError, with: :invalid_attachment

  def create
    EmailAttachmentWorkflow.add!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      draft_version: params[:draft_version],
      files: params[:files]
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: "email-reply"), notice: "Attachments added."
  end

  def destroy
    attachment = Current.workspace.stored_attachments.find(params[:attachment_id])
    EmailAttachmentWorkflow.remove!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      attachment: attachment,
      draft_version: params[:draft_version]
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: "email-reply"), notice: "Attachment removed."
  end

  private
    def forbidden
      render "shared/permission_denied", status: :forbidden
    end

    def invalid_attachment(error)
      @command_error = error.is_a?(ActiveRecord::StaleObjectError) ? "This draft changed in another session. Review it before changing attachments." : error.message
      load_workspace
      render "support_cases/show", status: :unprocessable_content
    end
end
