class KnowledgeSourcesController < ApplicationController
  include WorkspaceAuthorization

  before_action :require_workspace
  before_action :require_knowledge_manager, only: %i[ create update destroy ]

  def index
    load_index
  end

  def show
    load_source
  end

  def create
    source = KnowledgeIngestion.create!(
      workspace: Current.require_workspace!, membership: Current.require_membership!,
      **source_params.to_h.symbolize_keys
    )
    redirect_to workspace_knowledge_source_path(Current.workspace, source), notice: "Knowledge source added."
  rescue KnowledgeIngestion::InvalidSource, ActiveRecord::RecordInvalid => error
    @form_error = error.message
    load_index
    render :index, status: :unprocessable_content
  end

  def update
    source = Current.require_workspace!.knowledge_sources.find(params[:id])
    KnowledgeIngestion.update!(
      workspace: Current.workspace, membership: Current.require_membership!, knowledge_source: source,
      **version_params.to_h.symbolize_keys
    )
    redirect_to workspace_knowledge_source_path(Current.workspace, source), notice: "Knowledge version added."
  rescue KnowledgeIngestion::InvalidSource, ActiveRecord::RecordInvalid => error
    @form_error = error.message
    load_source
    render :show, status: :unprocessable_content
  end

  def destroy
    source = Current.require_workspace!.knowledge_sources.find(params[:id])
    KnowledgeIngestion.new(
      workspace: Current.workspace, membership: Current.require_membership!
    ).delete!(knowledge_source: source)
    redirect_to workspace_knowledge_source_path(Current.workspace, source), notice: "Knowledge source deleted from current use."
  end

  private
    def require_knowledge_manager
      head :forbidden unless Current.require_membership!.can_manage_work?
    end

    def source_params
      params.expect(knowledge_source: [ :source_kind, :title, :content, :url, :external_id, :upload, :expires_at ])
    end

    def version_params
      params.expect(knowledge_source: [ :content, :upload, :expires_at ])
    end

    def load_index
      workspace = Current.require_workspace!
      @sources = workspace.knowledge_sources.includes(:current_version).order(deleted_at: :asc, title: :asc, id: :asc)
      @query = params[:q].to_s
      @results = KnowledgeSearch.search(workspace:, query: @query)
      @can_manage = Current.require_membership!.can_manage_work?
    end

    def load_source
      @source = Current.require_workspace!.knowledge_sources
        .includes(versions: [ :created_by_user, :stored_attachment ])
        .find(params[:id])
      @versions = @source.versions
      @can_manage = Current.require_membership!.can_manage_work?
    end
end
