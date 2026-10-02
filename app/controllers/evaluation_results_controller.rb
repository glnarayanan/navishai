class EvaluationResultsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: :regression
  before_action :load_corpus

  def show
    @result = EvaluationResult.where(corpus: @corpus).find(params[:id])
    @item = @result.evaluation_run_item
    @checks = @result.eval_case.eval_case_checks.includes(grader_version: :grader, scenario_evidence: { corpus_item: :source_snapshot }).index_by(&:id)
    @suites = @corpus.eval_suites.where(kind: "regression").order(:name).limit(100)
    @sets = @corpus.calibration_sets.where(grader_version_id: @checks.values.map(&:grader_version_id)).order(:id)
  end

  def regression
    result = EvaluationResult.where(corpus: @corpus).find(params[:id])
    record = result.add_regression!(membership: Current.require_membership!, suite_id: params[:suite_id], rationale: params[:rationale].to_s)
    redirect_to workspace_corpus_eval_suite_path(Current.workspace, @corpus, record.eval_suite), notice: "Reviewed failure added to the regression suite with its fixed case and source result.", status: :see_other
  rescue EvalCase::Invalid, ActiveRecord::RecordInvalid => error
    show
    flash.now[:alert] = error.message
    render :show, status: :unprocessable_content
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
    end
end
