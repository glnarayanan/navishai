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
    attributes = source_params.to_h.symbolize_keys
    if attributes[:source_kind].to_s == "upload" && zip_bundle?(attributes[:upload])
      sources = KnowledgeIngestion.create_bundle!(
        workspace: Current.require_workspace!, membership: Current.require_membership!,
        title: attributes[:title], upload: attributes[:upload], expires_at: attributes[:expires_at]
      )
      return redirect_to workspace_knowledge_sources_path(Current.workspace),
        notice: "Added #{sources.size} knowledge #{'source'.pluralize(sources.size)} from the bundle."
    end

    source = KnowledgeIngestion.create!(
      workspace: Current.require_workspace!, membership: Current.require_membership!, **attributes
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

    def zip_bundle?(upload)
      return false if upload.respond_to?(:original_filename) && File.extname(upload.original_filename.to_s).downcase == ".docx"
      return false unless upload.respond_to?(:read) && upload.respond_to?(:rewind)

      signature = upload.read(4).to_s.b
      upload.rewind
      KnowledgeZipBundle.bundle?(signature)
    end

    def source_params
      params.expect(knowledge_source: [ :source_kind, :title, :content, :url, :external_id, :upload, :expires_at ])
    end

    def version_params
      params.expect(knowledge_source: [ :content, :upload, :expires_at ])
    end

    def load_index
      workspace = Current.require_workspace!
      @query = params[:q].to_s
      @support_case = workspace.support_cases.find(params[:support_case_id]) if params[:support_case_id].present?
      @sources = KnowledgeApplicabilityScope.new(workspace:, support_case: @support_case).sources.includes(:current_version, :knowledge_sync_observation).order(deleted_at: :asc, title: :asc, id: :asc)
      @results = KnowledgeSearch.search(workspace:, query: @query, support_case: @support_case)
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
