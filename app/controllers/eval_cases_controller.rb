class EvalCasesController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, except: :show
  before_action :load_corpus
  rescue_from EvalCase::Invalid, ActiveRecord::RecordInvalid, with: :invalid_input

  def new
    @scenario = @corpus.scenarios.find(params[:scenario_id])
    @version = @scenario.current_version
    raise ActiveRecord::RecordNotFound if @version.expired?
    @graders = @corpus.graders.includes(:current_version).order(:name).limit(100)
    @evidence = @version.scenario_evidence.includes(:corpus_item)
    @submitted_checks = (params.permit(checks: {})[:checks]&.to_h || {}).transform_values { |check| check.is_a?(Hash) ? check : {} }
  end

  def create
    scenario = @corpus.scenarios.find(params[:scenario_id])
    checks = (params.permit(checks: {})[:checks]&.to_h || {}).values
    item = EvalCompiler.call(scenario:, membership: Current.require_membership!, version_id: params[:version_id], checks:)
    redirect_to workspace_corpus_eval_case_path(Current.workspace, @corpus, item), notice: "Contract compiled with fixed graders and source references.", status: :see_other
  end

  def show
    @eval_case = @corpus.eval_cases.find(params[:id])
    @version = @eval_case.scenario_version
    raise ActiveRecord::RecordNotFound if @version.expired?
    @checks = @eval_case.eval_case_checks.includes(grader_version: :grader, scenario_evidence: :corpus_item).order(:requirement_kind, :requirement_index)
    @suites = @corpus.eval_suites.order(:name).limit(100)
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
    end

    def invalid_input(error)
      new
      flash.now[:alert] = error.message
      render :new, status: :unprocessable_content
    end
end
