class SetupsController < ApplicationController
  allow_unauthenticated_access
  before_action :require_available_bootstrap
  rate_limit to: 5, within: 10.minutes, only: :create, with: -> { redirect_to new_setup_path, alert: "Try again later." }

  def new
  end

  def create
    return redirect_to(new_setup_path, alert: "Bootstrap token is invalid.") unless FirstOwnerBootstrap.valid_token?(params[:bootstrap_token])

    user = FirstOwnerBootstrap.call(**setup_params.to_h.symbolize_keys)
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
