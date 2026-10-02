class CorporaController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: :create

  def index
    @corpora = Current.workspace.corpora.order(:name)
    @corpus = Corpus.new
  end

  def create
    membership = Current.require_membership!
    membership.with_lock do
      raise Current::RoleAccessDenied unless membership.can_write?
      @corpus = Current.workspace.corpora.build(params.expect(corpus: [ :name ]))
      @corpus.save!
    end
    redirect_to workspace_corpus_path(Current.workspace, @corpus), notice: "Corpus created.", status: :see_other
  rescue ActiveRecord::RecordInvalid
    @corpora = Current.workspace.corpora.order(:name)
    render :index, status: :unprocessable_content
  end

  def show
    @corpus = Current.workspace.corpora.find(params[:id])
    @sources = @corpus.sources.includes(:current_snapshot).order(:name)
    @analyses = @corpus.corpus_analyses.order(id: :desc).limit(10)
    @query = params[:corpus_query].to_s.strip
    @selected_source = @corpus.sources.where("expires_at > ?", Time.current).find(params[:source_id]) if params[:source_id].present?
    matching = @corpus.current_items
    matching = matching.where(sources: { id: @selected_source.id }) if @selected_source
    if @query.length > 200 || @query.include?("\0")
      @search_error = "Search needs at most 200 characters and no null bytes. Shorten the phrase and try again."
      matching = matching.none
    elsif @query.present?
      pattern = ActiveRecord::Relation::QueryAttribute.new("corpus_query",
        "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%", CorpusItem.type_for_attribute("content"))
      matching = matching.where("corpus_items.title ILIKE :pattern OR corpus_items.external_id ILIKE :pattern OR corpus_items.content ILIKE :pattern OR corpus_items.context::text ILIKE :pattern", pattern:)
    end
    @matching_count = matching.count
    @page = params[:page].to_i.clamp(1, 10000)
    @items = matching.includes(source_snapshot: :source).order(:id).offset((@page - 1) * 50).limit(51).to_a
    @more = @items.size > 50
    @items = @items.first(50)
    render :show, status: :unprocessable_content if @search_error
  end
end
