class EvalSuitesController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, except: %i[index show]
  before_action :load_corpus
  rescue_from EvalCase::Invalid, ActiveRecord::RecordInvalid, with: :invalid_input

  def index
    @suites = @corpus.eval_suites.order(:name).limit(100)
  end

  def create
    membership = Current.require_membership!
    @corpus.with_lock do
      @corpus.authorize_writer!(membership)
      @suite = @corpus.eval_suites.create!(params.expect(eval_suite: [ :name, :kind ]).merge(workspace: Current.workspace))
      AuditEvent.record!(action: "eval_suite.created", source: :web, workspace: Current.workspace, actor: Current.user, subject: @suite)
    end
    redirect_to workspace_corpus_eval_suite_path(Current.workspace, @corpus, @suite), notice: "Suite created. Add compiled cases from their contract pages.", status: :see_other
  end

  def show
    @suite = @corpus.eval_suites.find(params[:id])
    @cases = @suite.eval_cases.where(scenario_version: ScenarioVersion.unexpired).includes(:scenario_version).order(:id)
  end

  def update
    @suite = @corpus.eval_suites.find(params[:id])
    membership = Current.require_membership!
    @corpus.with_lock do
      @corpus.authorize_writer!(membership)
      if params[:remove_case_id].present?
        @suite.eval_suite_cases.find_by!(eval_case_id: params[:remove_case_id]).destroy!
      else
        @suite.add_case!(membership:, case_id: params[:case_id])
      end
      AuditEvent.record!(action: params[:remove_case_id].present? ? "eval_suite.case_removed" : "eval_suite.case_added", source: :web, workspace: Current.workspace, actor: Current.user, subject: @suite)
    end
    redirect_to workspace_corpus_eval_suite_path(Current.workspace, @corpus, @suite), notice: "Suite membership saved. Compiled definitions stay fixed.", status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
    end

    def invalid_input(error)
      flash.now[:alert] = error.message
      params[:id] ? show : index
      render params[:id] ? :show : :index, status: :unprocessable_content
    end
end
