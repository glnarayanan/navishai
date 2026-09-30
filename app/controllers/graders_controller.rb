class GradersController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, except: %i[index show]
  before_action :load_corpus
  rescue_from EvalCase::Invalid, SupportOutput::Invalid, EvaluationHttp::Error, ActiveRecord::RecordInvalid, JSON::ParserError, with: :invalid_input

  def index
    @page = params[:page].to_i.clamp(1, 10000)
    @graders = @corpus.graders.includes(:current_version).order(:id).offset((@page - 1) * 50).limit(51).to_a
    @more = @graders.size > 50
    @graders = @graders.first(50)
    @values ||= { "kind" => "deterministic", "check_type" => "tool_called", "confidence_threshold" => 0.8 }
  end

  def show
    @grader = @corpus.graders.find(params[:id])
    @versions = @grader.grader_versions.order(number: :desc)
    @version = params[:version] ? @versions.find_by!(number: params[:version]) : @grader.current_version
    @values ||= { "name" => @grader.name, "kind" => @version.kind, "check_type" => @version.definition["type"],
      "value" => Array(@version.definition["value"]).join("\n"), "rubric" => @version.definition["rubric"], "confidence_threshold" => @version.definition["confidence_threshold"] || 0.8,
      "judge_configuration" => @version.definition["execution"] && JSON.pretty_generate(@version.definition["execution"]) }
  end

  def create
    read_definition
    grader = Grader.define!(corpus: @corpus, membership: Current.require_membership!, name: @values["name"], kind: @values["kind"], definition: @definition)
    redirect_to workspace_corpus_grader_path(Current.workspace, @corpus, grader), notice: "Fixed grader version created. Calibration still needs expert labels.", status: :see_other
  end

  def update
    read_definition
    grader = @corpus.graders.find(params[:id])
    grader.revise!(membership: Current.require_membership!, version_id: params[:version_id], kind: @values["kind"], definition: @definition)
    redirect_to workspace_corpus_grader_path(Current.workspace, @corpus, grader), notice: "Saved. Compiled cases keep their prior grader version.", status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
    end

    def read_definition
      @values = params.expect(grader: [ :name, :kind, :check_type, :value, :rubric, :confidence_threshold, :judge_configuration ]).to_h
      @definition = if @values["kind"] == "deterministic"
        { "type" => @values["check_type"], "value" => @values["check_type"] == "tool_before" ? @values["value"].to_s.lines.map(&:strip) : @values["value"].to_s.strip }
      else
        { "rubric" => @values["rubric"].to_s, "confidence_threshold" => Float(@values["confidence_threshold"], exception: false) }
      end
      if @values["kind"] == "rubric_judge" && @values["judge_configuration"].present?
        raise SupportOutput::Invalid, "Judge configuration must be at most 8 KiB." if @values["judge_configuration"].bytesize > 8.kilobytes
        @definition["execution"] = JSON.parse(@values["judge_configuration"])
      end
    end

    def invalid_input(error)
      flash.now[:alert] = error.is_a?(JSON::ParserError) ? "Judge configuration must be valid JSON. Correct it and save again." : error.message
      params[:id] ? show : index
      render params[:id] ? :show : :index, status: :unprocessable_content
    end
end
