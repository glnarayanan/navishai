class SetupsController < ApplicationController
  allow_unauthenticated_access
  before_action :require_available_bootstrap
  rate_limit(**SecurityRateLimits::SENSITIVE, only: :create, with: -> { redirect_to new_setup_path, alert: "Try again later." })

  def new
  end

  def create
    return redirect_to(new_setup_path, alert: "Bootstrap token is invalid.") unless FirstOwnerBootstrap.valid_token?(params[:bootstrap_token])

    user = ApplicationRecord.transaction do
      FirstOwnerBootstrap.call(**setup_params.to_h.symbolize_keys).tap do |created_user|
        workspace = created_user.workspaces.sole
        audit_event("installation.bootstrapped", workspace: workspace, actor: created_user, subject: workspace)
      end
    end
    redirect_to start_new_session_for(user), notice: "Owner workspace created.", status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    flash.now[:alert] = error.record.errors.full_messages.to_sentence
    render :new, status: :unprocessable_content
  rescue FirstOwnerBootstrap::Unavailable
    head :not_found
  end

  private
    def require_available_bootstrap
      head :not_found unless FirstOwnerBootstrap.available?
    end

    def setup_params
      params.expect(setup: [
        :organization_name,
        :organization_slug,
        :workspace_name,
        :workspace_slug,
        :email_address,
        :password,
        :password_confirmation
      ])
    end
end
