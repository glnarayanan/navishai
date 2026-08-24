class EmailRepliesController < SupportCasesController
  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError, ArgumentError, with: :invalid_reply

  def save_draft
    EmailDraftWorkflow.save!(
      workspace: Current.workspace,
      support_case: @support_case,
      membership: Current.require_membership!,
      body: params[:body],
      expected_lock_version: params[:draft_version]
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
      idempotency_key: params[:idempotency_key]
    )
    if delivery.sent?
      redirect_to workspace_support_case_path(Current.workspace, @support_case), notice: "Email sent."
    else
      message = delivery.unknown? ? "Delivery outcome needs review. Do not resend." : "Email was not sent. Check SMTP settings and try a fresh send."
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
    notice = params[:outcome] == "accepted" ? "Delivery marked as accepted." : "Delivery marked as not sent. You can send a fresh reply."
    redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: "email-reply"), notice: notice
  end

  private
    def forbidden
      render "shared/permission_denied", status: :forbidden
    end

    def invalid_reply(error)
      @command_error = error.is_a?(ActiveRecord::StaleObjectError) ? "This draft changed in another session. Review the latest draft before sending." : error.message
      @submitted_email_body = params[:body] unless error.is_a?(ActiveRecord::StaleObjectError)
      @send_token = params[:idempotency_key].presence || SecureRandom.uuid
      load_workspace
      render "support_cases/show", status: :unprocessable_content
    end
end
