class PagesController < ApplicationController
  allow_unauthenticated_access

  def show
    redirect_to workspaces_path if authenticated?
  end

  def privacy
  end

  def terms
  end
end
