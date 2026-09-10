class WorkspaceSearchSettingsController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action -> { require_role(:owner, :admin) }

  def edit
    load_catalog
  end

  def update
    load_catalog
    return render :edit, status: :service_unavailable if @catalog_error

    key = params.expect(workspace: [ :web_search_provider_key ])[:web_search_provider_key].presence
    unless key.nil? || @provider_keys.include?(key)
      @workspace.errors.add(:web_search_provider_key, "is not available")
      return render :edit, status: :unprocessable_content
    end
    @workspace.with_lock do
      previous = @workspace.web_search_provider_key
      @workspace.update!(web_search_provider_key: key)
      audit_event("workspace.search_provider_updated", subject: @workspace,
        metadata: { previous_provider: previous.to_s, provider: key.to_s })
    end
    redirect_to edit_workspace_search_settings_path(@workspace), notice: "Search provider saved.", status: :see_other
  end

  private
    def load_catalog
      @workspace = Current.require_workspace!
      catalog = RunnerClient.new.web_search_catalog!(workspace_key: @workspace.runner_key)
      @provider_keys = catalog.fetch("provider_keys")
      @default_provider_key = catalog.fetch("default_provider_key").presence
    rescue RunnerClient::Error
      @provider_keys = []
      @catalog_error = "Search providers are unavailable. Your saved choice has been preserved. Try again when the runner is available."
    end
end
