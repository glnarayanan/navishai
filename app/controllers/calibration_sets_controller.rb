class CalibrationSetsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: :create
  before_action :load_corpus
  rescue_from EvalCase::Invalid, ActiveRecord::RecordInvalid, with: :invalid_input

  def index
    @sets = @corpus.calibration_sets.includes(grader_version: :grader).order(id: :desc).limit(100)
    @graders = @corpus.grader_versions.includes(:grader).order(id: :desc).limit(100)
  end

  def create
    values = params.expect(calibration_set: [ :name, :grader_version_id ]).to_h
    set = CalibrationSet.define!(corpus: @corpus, membership: Current.require_membership!, **values.symbolize_keys)
    redirect_to workspace_corpus_calibration_set_path(Current.workspace, @corpus, set), notice: "Calibration set created for this fixed grader version.", status: :see_other
  end

  def show
    @set = @corpus.calibration_sets.find(params[:id])
    @cohort = %w[development held_out].include?(params[:cohort]) ? params[:cohort] : "held_out"
    @report = CalibrationReport.call(set: @set, cohort: @cohort)
    @samples = @set.calibration_samples.where(cohort: @cohort).order(:id)
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
    end

    def invalid_input(error)
      index
      flash.now[:alert] = error.message
      render :index, status: :unprocessable_content
    end
end
