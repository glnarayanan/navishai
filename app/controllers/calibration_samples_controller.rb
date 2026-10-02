class CalibrationSamplesController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, except: :show
  before_action :load_set
  rescue_from EvalCase::Invalid, EvaluationHttp::Error, SupportOutput::Invalid, ActiveRecord::RecordInvalid, JSON::ParserError, with: :invalid_input

  def new
    @checks = EvalCaseCheck.where(corpus: @corpus, grader_version: @set.grader_version).includes(eval_case: :scenario_version).order(id: :desc).limit(100)
  end

  def create
    raise SupportOutput::Invalid, "Output must be support-output-v1 JSON of at most 100 KiB." if params[:output].to_s.bytesize > SupportOutput::MAX_BYTES
    sample = @set.add_sample!(membership: Current.require_membership!, check_id: params[:check_id], cohort: params[:cohort], output: JSON.parse(params[:output].to_s))
    redirect_to workspace_corpus_calibration_set_calibration_sample_path(Current.workspace, @corpus, @set, sample), notice: "Fixed sample saved. Label the behaviour before seeing its machine prediction.", status: :see_other
  end

  def show
    @sample = @set.calibration_samples.find(params[:id])
    @check = @sample.eval_case_check
    @labels = @sample.latest_labels.includes(:labelled_by).order(:labelled_by_id)
    @own_label = @labels.find { |label| label.labelled_by_id == Current.user.id }
    @reveal = @own_label.present? || !Current.require_membership!.can_write?
    @judge_run = @sample.calibration_judge_run
  end

  def judge
    sample = @set.calibration_samples.find(params[:id])
    CalibrationJudgeRun.request!(sample:, membership: Current.require_membership!, disclose: params[:judge_disclose] == "1")
    redirect_to workspace_corpus_calibration_set_calibration_sample_path(Current.workspace, @corpus, @set, sample), notice: "Judge attempt recorded. Refresh to see its state; refresh never sends a new request.", status: :see_other
  end

  def interrupt_judge
    sample = @set.calibration_samples.find(params[:id])
    sample.calibration_judge_run&.interrupt!(membership: Current.require_membership!)
    redirect_to workspace_corpus_calibration_set_calibration_sample_path(Current.workspace, @corpus, @set, sample), notice: "Judge attempt interrupted. It will not retry automatically.", status: :see_other
  end

  def label
    sample = @set.calibration_samples.find(params[:id])
    sample.label!(membership: Current.require_membership!, previous_id: params[:previous_id], decision: params[:decision], rationale: params[:rationale].to_s)
    redirect_to workspace_corpus_calibration_set_calibration_sample_path(Current.workspace, @corpus, @set, sample), notice: "Expert label saved. Prior labels remain in history.", status: :see_other
  end

  private
    def load_set
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
      @set = @corpus.calibration_sets.find(params[:calibration_set_id])
    end

    def invalid_input(error)
      message = error.is_a?(JSON::ParserError) ? "Output must be valid JSON. Correct the sample and try again." : error.message
      if params[:id]
        show
        flash.now[:alert] = message
        render :show, status: :unprocessable_content
      else
        new
        flash.now[:alert] = message
        render :new, status: :unprocessable_content
      end
    end
end
