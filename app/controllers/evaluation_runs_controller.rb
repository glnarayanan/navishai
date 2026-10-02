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
    run = EvaluationRun.request!(suite:, membership: Current.require_membership!, target_version_id: params[:target_version_id], disclose: params[:disclose] == "1", judge_disclose: params[:judge_disclose] == "1", suite_digest: params[:suite_digest])
    redirect_to workspace_corpus_evaluation_run_path(Current.workspace, @corpus, run), notice: "Run queued with fixed case inputs and target version. Refresh to see results.", status: :see_other
  rescue EvalCase::Invalid, HttpTarget::Error, RecordedTarget::Error, SupportOutput::Invalid => error
    redirect_to workspace_corpus_eval_suite_path(Current.workspace, @corpus, suite), alert: error.message, status: :see_other
  end

  def show
    @run = @corpus.evaluation_runs.find(params[:id])
    @corpus.with_lock do
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
      @items = @run.evaluation_run_items.includes(:evaluation_result, eval_case: [ :scenario_version,
        { eval_case_checks: [ { grader_version: :grader }, :scenario_evidence ] } ]).order(:id).to_a
      evidence = @items.flat_map { |item| item.eval_case.eval_case_checks.map(&:scenario_evidence) }.uniq(&:id)
      ActiveRecord::Associations::Preloader.new(records: evidence, associations: :corpus_item,
        scope: CorpusItem.select(:id, :workspace_id, :corpus_id, :source_snapshot_id, :external_id).includes(:source_snapshot)).call
      @failure_patterns = EvaluationFailurePatterns.call(items: @items)
    end
    @baseline_options = @corpus.evaluation_runs.where.not(id: @run.id).includes(:evaluation_target_version).order(id: :desc).limit(100).to_a
    if params[:baseline_id].present?
      @baseline = @corpus.evaluation_runs.find(params[:baseline_id])
      @comparison = @run.compare_with(baseline: @baseline)
      @baseline_options << @baseline unless @baseline_options.include?(@baseline)
    end
  rescue EvalCase::Invalid => error
    redirect_to workspace_corpus_evaluation_run_path(Current.workspace, @corpus, @run), alert: error.message, status: :see_other
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
