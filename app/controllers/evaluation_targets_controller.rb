class EvaluationTargetsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager) }, except: %i[index show]
  before_action :load_corpus
  rescue_from EvalCase::Invalid, HttpTarget::Error, SupportOutput::Invalid, ActiveRecord::RecordInvalid, JSON::ParserError, with: :invalid_input

  def index
    @targets = @corpus.evaluation_targets.includes(:current_version).order(:id).limit(100)
  end

  def show
    @target = @corpus.evaluation_targets.find(params[:id])
    @versions = @target.evaluation_target_versions.order(number: :desc)
    @version = params[:version] ? @versions.find_by!(number: params[:version]) : @target.current_version
  end

  def create
    read_configuration
    target = EvaluationTarget.define!(corpus: @corpus, membership: Current.require_membership!, name: params[:name], configuration: @configuration, adapter: params[:adapter] || "scripted")
    redirect_to workspace_corpus_evaluation_target_path(Current.workspace, @corpus, target), notice: "Target saved. Saving a definition does not send data or execute it.", status: :see_other
  end

  def update
    read_configuration
    target = @corpus.evaluation_targets.find(params[:id])
    target.revise!(membership: Current.require_membership!, version_id: params[:version_id], configuration: @configuration)
    redirect_to workspace_corpus_evaluation_target_path(Current.workspace, @corpus, target), notice: "Target version saved. Prior runs keep their original version.", status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
    end

    def read_configuration
      raise SupportOutput::Invalid, "Target configuration must be at most 1 MiB." if params[:configuration].to_s.bytesize > ScriptedTarget::MAX_BYTES
      @configuration = JSON.parse(params[:configuration].to_s)
    end

    def invalid_input(error)
      flash.now[:alert] = error.is_a?(JSON::ParserError) ? "Configuration must be valid JSON. Correct it and save again." : error.message
      params[:id] ? show : index
      render params[:id] ? :show : :index, status: :unprocessable_content
    end
end
