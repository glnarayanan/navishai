class CorpusAnalysesController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: %i[create update]
  before_action :load_corpus

  def create
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: Current.require_membership!, scenario_limit: params[:scenario_limit])
    redirect_to workspace_corpus_corpus_analysis_path(Current.workspace, @corpus, analysis), notice: "Local analysis queued. Refresh to see its result.", status: :see_other
  rescue CorpusIntake::Invalid, ActiveRecord::RecordInvalid => error
    redirect_to workspace_corpus_path(Current.workspace, @corpus), alert: error.message, status: :see_other
  end

  def show
    @analysis = @corpus.corpus_analyses.find(params[:id])
    raise ActiveRecord::RecordNotFound if @analysis.expired?
    @page = params[:page].to_i.clamp(1, 10000)
    @clusters = @analysis.issue_clusters.includes(cluster_members: :corpus_item).order(:id).offset((@page - 1) * 10).limit(11).to_a
    @more = @clusters.size > 10
    @clusters = @clusters.first(10)
    @taxonomy = @analysis.latest_taxonomy
  end

  def update
    analysis = @corpus.corpus_analyses.find(params[:id])
    TaxonomyVersion.review!(analysis:, membership: Current.require_membership!, cluster_id: params[:cluster_id], label: params[:label])
    redirect_to workspace_corpus_corpus_analysis_path(Current.workspace, @corpus, analysis), notice: "Expert taxonomy revision saved.", status: :see_other
  rescue CorpusIntake::Invalid => error
    redirect_to workspace_corpus_corpus_analysis_path(Current.workspace, @corpus, analysis), alert: error.message, status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
    end
end
