class IntercomRepliesController < SupportCasesController
  rescue_from Current::RoleAccessDenied, with: :forbidden
  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError,
    IntercomClient::Error, ArgumentError, with: :invalid_reply

  def save_draft
    IntercomDraftWorkflow.save!(
      workspace: Current.workspace, support_case: @support_case,
      membership: Current.require_membership!, body: params[:body],
      expected_lock_version: params[:draft_version],
      source_crew_artifact_id: params[:source_crew_artifact_id],
      adopt_source: params[:adopt_source] == "1"
    )
    redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: "intercom-reply"), notice: "Intercom draft saved."
  end

  def send_reply
    delivery = HumanIntercomSend.send!(
      workspace: Current.workspace, support_case: @support_case,
      membership: Current.require_membership!, body: params[:body],
      draft_version: params[:draft_version], idempotency_key: params[:idempotency_key],
      source_crew_artifact_id: params[:source_crew_artifact_id],
      expected_source_part_id: params[:expected_source_part_id]
    )
    message = if delivery.sent?
      { notice: "Intercom reply sent.", anchor: nil }
    elsif delivery.unknown?
      { alert: "Delivery outcome needs review. Do not resend.", anchor: "intercom-reply" }
    else
      { alert: "Intercom did not accept the reply. Check the connection and try a fresh send.", anchor: "intercom-reply" }
    end
    redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: message.delete(:anchor)), **message
  end

  def review_delivery
    delivery = Current.workspace.intercom_outbound_deliveries.find(params[:delivery_id])
    HumanIntercomSend.review_unknown!(
      workspace: Current.workspace, support_case: @support_case,
      membership: Current.require_membership!, delivery: delivery,
      outcome: params[:outcome], remote_part_id: params[:remote_part_id]
    )
    notice = delivery.reload.sent? ? "Delivery marked as accepted." : "Delivery marked as not sent. You can send a fresh reply."
    redirect_to workspace_support_case_path(Current.workspace, @support_case, anchor: "intercom-reply"), notice: notice
  end

  private
    def forbidden
      render "shared/permission_denied", status: :forbidden
    end

    def invalid_reply(error)
      @command_error = error.is_a?(ActiveRecord::StaleObjectError) ?
        "This draft changed in another session. Review the latest draft before sending." : error.message
      @submitted_intercom_body = params[:body] unless error.is_a?(ActiveRecord::StaleObjectError)
      @intercom_send_token = params[:idempotency_key].presence || SecureRandom.uuid
      load_workspace
      render "support_cases/show", status: :unprocessable_content
    end
end
