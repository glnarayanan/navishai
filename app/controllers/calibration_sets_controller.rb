class CalibrationSetsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: :create
  before_action :load_corpus
  rescue_from EvalCase::Invalid, SupportOutput::Invalid, ActiveRecord::RecordInvalid, with: :invalid_input

  def index
    @sets = @corpus.calibration_sets.includes(grader_version: :grader).order(id: :desc).limit(100)
    @graders = @corpus.grader_versions.includes(:grader).order(id: :desc).limit(100)
  end

  def create
    values = params.expect(calibration_set: [ :name, :grader_version_id, :false_positive_cost, :false_negative_cost, :error_cost_unit, :error_cost_rationale ]).to_h
    set = CalibrationSet.define!(corpus: @corpus, membership: Current.require_membership!, **values.symbolize_keys)
    redirect_to workspace_corpus_calibration_set_path(Current.workspace, @corpus, set), notice: "Calibration set created for this fixed grader version.", status: :see_other
  end

  def show
    @set = @corpus.calibration_sets.find(params[:id])
    @cohort = %w[development held_out].include?(params[:cohort]) ? params[:cohort] : "held_out"
    @report = CalibrationReport.call(set: @set, cohort: @cohort, reviewer: Current.user)
    @candidates = @set.grader_version.grader.grader_versions.where(kind: "deterministic").where("number > ?", @set.grader_version.number).order(number: :desc).limit(100)
    @candidate = @candidate_report = nil
    if params[:candidate_version_id].present? && !@preview_error
      @candidate = @corpus.grader_versions.find(params[:candidate_version_id])
      @candidate_report = CalibrationReport.call(set: @set, cohort: @cohort, candidate: @candidate, reviewer: Current.user)
    end
    @reviews = @report.fetch(:reviews)
    if Current.require_membership!.can_write?
      @review_state = params[:review_state] if CalibrationReport::REVIEW_STATES.key?(params[:review_state])
      @reviews = @reviews.select { |entry| entry[:state] == @review_state } if @review_state
      @reviews = @reviews.sort_by { |entry| [ CalibrationReport::REVIEW_STATES.keys.index(entry[:state]), entry[:sample].id ] }
      @next_unlabelled = @reviews.find { |entry| entry[:state] == "unlabelled" }&.fetch(:sample)
    end
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
    end

    def invalid_input(error)
      flash.now[:alert] = error.message
      @cost_errors = error.record.errors.full_messages_for(:false_positive_cost) + error.record.errors.full_messages_for(:false_negative_cost) + error.record.errors.full_messages_for(:error_cost_unit) + error.record.errors.full_messages_for(:error_cost_rationale) if error.is_a?(ActiveRecord::RecordInvalid)
      if action_name == "show"
        @preview_error = true
        show
        render :show, status: :unprocessable_content
      else
        index
        render :index, status: :unprocessable_content
      end
    end
end
