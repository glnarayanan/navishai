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
    @page = [ params[:page].to_i, 1 ].max
    @items = @corpus.current_items.order(:id).offset((@page - 1) * 50).limit(51).to_a
    @more = @items.size > 50
    @items = @items.first(50)
  end
end
