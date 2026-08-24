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
      @inboxes = workspace.shared_email_inboxes.order(:name, :id)
      retryable = workspace.inbound_email_deliveries.outstanding
      terminal = workspace.inbound_email_deliveries.where(status: %w[received failed]).where.not(id: retryable.select(:id))
      @retry_counts = retryable.group(:shared_email_inbox_id).count
      @retry_failure_counts = retryable
        .group(:shared_email_inbox_id, :failure_code)
        .count
      @terminal_failure_counts = terminal
        .group(:shared_email_inbox_id, :failure_code)
        .count
      @inbox = inbox
    end
end
