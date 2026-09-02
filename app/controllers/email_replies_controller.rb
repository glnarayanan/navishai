class EmailRepliesController < SupportCasesController
  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError,
    AttachmentIntake::InvalidAttachment, ArgumentError, with: :invalid_reply

  def save_draft
    EmailDraftWorkflow.save!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      body: params[:body],
      expected_lock_version: params[:draft_version],
      source_crew_artifact_id: params[:source_crew_artifact_id],
      adopt_source: params[:adopt_source] == "1"
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: "email-reply"), notice: "Draft saved."
  end

  def send_email
    delivery = HumanEmailSend.send!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      body: params[:body],
      draft_version: params[:draft_version],
      idempotency_key: params[:idempotency_key],
      source_crew_artifact_id: params[:source_crew_artifact_id],
      expected_recipient_address: params[:expected_recipient_address],
      expected_inbound_message_id: params[:expected_inbound_message_id],
      confirmed_recipient_address: params[:confirmed_recipient_address]
    )
    if delivery.sent?
      redirect_to workspace_support_case_path(Current.workspace, @support_case), notice: "Email sent."
    else
      message = if delivery.unknown?
        "Delivery outcome needs review. Do not resend."
      elsif delivery.failure_code == "attachment_unavailable"
        "Email was not sent because an attachment changed or could not be read. Remove it, add the file again, then retry."
      else
        "Email was not sent. Check SMTP settings and try a fresh send."
      end
      redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: "email-reply"), alert: message
    end
  end

  def review_delivery
    delivery = Current.workspace.outbound_email_deliveries.find(params[:delivery_id])
    HumanEmailSend.review_unknown!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      delivery: delivery,
      outcome: params[:outcome]
    )
    notice = delivery.reload.sent? ? "Delivery marked as accepted." : "Delivery marked as not sent. You can send a fresh reply."
    redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: "email-reply"), notice: notice
  end

  private
    def invalid_reply(error)
      @command_error = error.is_a?(ActiveRecord::StaleObjectError) ? "This draft changed in another session. Review the latest draft before sending." : error.message
      @submitted_email_body = params[:body] unless error.is_a?(ActiveRecord::StaleObjectError)
      @send_token = params[:idempotency_key].presence || SecureRandom.uuid
      load_workspace
      render "support_cases/show", status: :unprocessable_content
    end
end
