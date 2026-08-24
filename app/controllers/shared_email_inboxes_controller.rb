class SharedEmailInboxesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :require_integration_admin

  def index
    load_index
  end

  def create
    inbox = SharedEmailInbox.transaction do
      Current.require_workspace!.shared_email_inboxes.create!(inbox_params).tap do |created_inbox|
        audit_event("email.inbox_created", subject: created_inbox)
      end
    end
    redirect_to workspace_shared_email_inboxes_path(Current.workspace), notice: "Email inbox added."
  rescue ActiveRecord::RecordInvalid => error
    load_index(inbox: error.record)
    render :index, status: :unprocessable_content
  end

  def update
    inbox = Current.require_workspace!.shared_email_inboxes.find(params[:id])
    SharedEmailInbox.transaction do
      inbox.lock!
      inbox.update!(active: params.require(:shared_email_inbox).require(:active))
      audit_event("email.inbox_updated", subject: inbox, metadata: { active: inbox.active?.to_s })
    end
    redirect_to workspace_shared_email_inboxes_path(Current.workspace), notice: "Email inbox updated."
  end

  def reconcile
    inbox = Current.require_workspace!.shared_email_inboxes.find(params[:id])
    deliveries = SharedEmailIntake.reconcile!(inbox: inbox, membership: Current.require_membership!)
    redirect_to workspace_shared_email_inboxes_path(Current.workspace), notice: "Retried #{deliveries.size} email deliveries."
  end

  private
    def require_integration_admin
      head :forbidden unless Current.require_membership!.can_configure_integrations?
    end

    def inbox_params
      params.expect(shared_email_inbox: [ :name, :email_address, :credential_key ])
    end

    def load_index(inbox: SharedEmailInbox.new)
      workspace = Current.require_workspace!
      @inboxes = workspace.shared_email_inboxes
        .left_joins(:inbound_email_deliveries)
        .select("shared_email_inboxes.*, COUNT(inbound_email_deliveries.id) FILTER (WHERE inbound_email_deliveries.status IN ('received', 'failed')) AS outstanding_delivery_count")
        .group(:id)
        .order(:name, :id)
      @failure_counts = workspace.inbound_email_deliveries.outstanding
        .group(:shared_email_inbox_id, :failure_code)
        .count
      @inbox = inbox
    end
end
