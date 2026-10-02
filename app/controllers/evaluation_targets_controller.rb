class EvaluationTargetsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager) }, except: %i[index show]
  before_action :load_corpus
  rescue_from EvalCase::Invalid, HttpTarget::Error, RecordedTarget::Error, SupportOutput::Invalid, ActiveRecord::RecordInvalid, JSON::ParserError, with: :invalid_input

  def index
    @targets = @corpus.evaluation_targets.includes(:current_version).order(:id).limit(100)
  end

  def show
    @target = @corpus.evaluation_targets.find(params[:id])
    @versions = @target.evaluation_target_versions.order(number: :desc)
    @version = params[:version] ? @versions.find_by!(number: params[:version]) : @target.current_version
  end

  def create
    adapter = params[:adapter] || "scripted"
    read_configuration(adapter:)
    target = EvaluationTarget.define!(corpus: @corpus, membership: Current.require_membership!, name: params[:name], configuration: @configuration, adapter:, trace_item_id: params[:trace_item_id])
    redirect_to workspace_corpus_evaluation_target_path(Current.workspace, @corpus, target), notice: "Target saved. Saving a definition does not send data or execute it.", status: :see_other
  end

  def update
    target = @corpus.evaluation_targets.find(params[:id])
    read_configuration(adapter: target.current_version.adapter)
    target.revise!(membership: Current.require_membership!, version_id: params[:version_id], configuration: @configuration, trace_item_id: params[:trace_item_id])
    redirect_to workspace_corpus_evaluation_target_path(Current.workspace, @corpus, target), notice: "Target version saved. Prior runs keep their original version.", status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
      raise ActiveRecord::RecordNotFound if @corpus.eval_definitions_expired?
    end

    def read_configuration(adapter:)
      if adapter == "recorded"
        @configuration = {}
        return
      end
      raise SupportOutput::Invalid, "Target configuration must be at most 1 MiB." if params[:configuration].to_s.bytesize > ScriptedTarget::MAX_BYTES
      @configuration = JSON.parse(params[:configuration].to_s)
    end

    def invalid_input(error)
      flash.now[:alert] = error.is_a?(JSON::ParserError) ? "Configuration must be valid JSON. Correct it and save again." : error.message
      params[:id] ? show : index
      render params[:id] ? :show : :index, status: :unprocessable_content
    end
end
