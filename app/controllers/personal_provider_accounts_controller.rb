class PersonalProviderAccountsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action :require_writer
  before_action :prevent_credential_caching
  rescue_from RunnerClient::Error, with: :runner_failed

  def index
    @accounts = own_accounts.includes(:runtime_installation).order(created_at: :desc)
  end

  def create
    provider = ProviderConnectionGateway.new.catalog(workspace_key: Current.workspace.runner_key).find { |item| item["adapter_key"] == "codex_subscription" }
    unless provider && provider["configured"] && provider["auth_mode"] == "subscription" && provider["execution_mode"] == "strong_isolated"
      redirect_to workspace_personal_provider_accounts_path(Current.workspace), alert: "An Admin must enable server-side Codex subscription access first."
      return
    end
    @account = own_accounts.create!
    perform_operation("start")
    audit_event("runtime.personal_account_started", workspace: Current.workspace, subject: @account)
    render :show, status: :created
  end

  def show
    @account = own_accounts.find(params[:id])
    perform_operation("status")
  end

  def refresh
    account = own_accounts.find(params[:id])
    redirect_to workspace_personal_provider_account_path(Current.workspace, account), status: :see_other
  end

  def destroy
    @account = own_accounts.find(params[:id])
    perform_operation("disconnect")
    audit_event("runtime.personal_account_disconnected", workspace: Current.workspace, subject: @account)
    redirect_to workspace_personal_provider_accounts_path(Current.workspace), notice: "Your AI account was disconnected."
  end

  private
    def own_accounts
      PersonalProviderAccount.where(workspace: Current.workspace, membership: Current.require_membership!)
    end

    def perform_operation(action)
      @result = PersonalProviderGateway.new.account(action:, workspace_key: Current.workspace.runner_key,
        membership_id: Current.require_membership!.id, account_key: @account.account_key)
      PersonalProviderConnection.refresh!(account: @account, result: @result)
    end

    def require_writer
      head :forbidden unless Current.require_membership!.can_write?
    end

    def prevent_credential_caching
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["Pragma"] = "no-cache"
      response.headers["Referrer-Policy"] = "same-origin"
    end

    def runner_failed
      redirect_to workspace_personal_provider_accounts_path(Current.workspace), alert: "The provider service could not confirm the operation. Check your account status before trying again."
    end
end
