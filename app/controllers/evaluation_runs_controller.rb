class EvaluationRunsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, except: %i[index show]
  before_action :load_corpus

  def index
    @page = params[:page].to_i.clamp(1, 10000)
    @runs = @corpus.evaluation_runs.includes(:eval_suite, evaluation_target_version: :evaluation_target).order(id: :desc).offset((@page - 1) * 50).limit(51).to_a
    @more = @runs.size > 50
    @runs = @runs.first(50)
  end

  def create
    suite = @corpus.eval_suites.find(params[:suite_id])
    run = EvaluationRun.request!(suite:, membership: Current.require_membership!, target_version_id: params[:target_version_id], disclose: params[:disclose] == "1")
    redirect_to workspace_corpus_evaluation_run_path(Current.workspace, @corpus, run), notice: "Run queued with fixed case inputs and target version. Refresh to see results.", status: :see_other
  rescue EvalCase::Invalid, HttpTarget::Error, SupportOutput::Invalid => error
    redirect_to workspace_corpus_eval_suite_path(Current.workspace, @corpus, suite), alert: error.message, status: :see_other
  end

  def show
    @run = @corpus.evaluation_runs.find(params[:id])
    @items = @run.evaluation_run_items.includes(:evaluation_result, eval_case: :scenario_version).order(:id)
    @failures = @items.flat_map do |item|
      (item.evaluation_result&.decisions || []).select { |decision| decision["decision"] == "fail" }.map { |decision| [ item, decision ] }
    end.group_by { |_item, decision| decision.fetch("grader_version_id") }
    @graders = @corpus.grader_versions.where(id: @failures.keys).includes(:grader).index_by(&:id)
  end

  def update
    run = @corpus.evaluation_runs.find(params[:id])
    run.interrupt!(membership: Current.require_membership!)
    redirect_to workspace_corpus_evaluation_run_path(Current.workspace, @corpus, run), notice: "Run interrupted. No automatic retry will occur.", status: :see_other
  rescue EvalCase::Invalid => error
    redirect_to workspace_corpus_evaluation_run_path(Current.workspace, @corpus, run), alert: error.message, status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
    end
end
