class AssumptionImpactsController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: %i[new create interrupt]
  before_action :load_corpus

  def index
    @corpus.with_lock do
      @expired = @corpus.eval_definitions_expired?
      @page = params[:page].to_i.clamp(1, 10000)
      attempts = AssumptionImpact.where(corpus: @corpus)
      @count = @expired ? nil : attempts.count
      @impacts = @expired ? [] : attempts.select(:id, :state, :created_at, :before_snapshot_id, :after_snapshot_id).order(id: :desc).offset((@page - 1) * 50).limit(50).to_a
    end
  end

  def new
    prepare_preview
  end

  def create
    raise CorpusIntake::Invalid, "Model configuration must be JSON of at most 10 KiB." unless params[:configuration].is_a?(String) && params[:configuration].bytesize <= 10.kilobytes
    configuration = JSON.parse(params[:configuration])
    impact = AssumptionImpact.request!(corpus: @corpus, membership: Current.require_membership!,
      source_id: params[:source_id], before_snapshot_id: params[:before_snapshot_id], after_snapshot_id: params[:after_snapshot_id],
      version_ids: params[:version_ids], configuration:, input_digest: params[:input_digest],
      disclose: params[:impact_disclose] == "1", historical: params[:historical_confirm] == "1")
    redirect_to workspace_corpus_assumption_impact_path(Current.workspace, @corpus, impact),
      notice: "Fixed change-analysis attempt opened. Refresh or duplicate submission never sends another request.", status: :see_other
  rescue CorpusIntake::Invalid, SupportOutput::Invalid, EvaluationHttp::Error, JSON::ParserError => error
    prepare_preview
    flash.now[:alert] = error.is_a?(JSON::ParserError) ? "Model configuration must be valid JSON. Repair it and confirm disclosure again." : error.message
    render :new, status: :unprocessable_content
  end

  def show
    @corpus.with_lock do
      @impact = AssumptionImpact.where(corpus: @corpus).find(params[:id])
      raise ActiveRecord::RecordNotFound if @impact.expired?
      @input = @impact.input
      @result = @impact.assumption_impact_result&.result
      @source_changed = @impact.source.reload.current_snapshot_id != @impact.source_head_id ||
        @impact.source.source_snapshots.maximum(:number) != @input.fetch("source_latest_snapshot_number")
      @current_versions = @corpus.scenarios.where(id: @input.fetch("scenarios").pluck("scenario_id")).pluck(:id, :current_version_id).to_h
    end
  end

  def interrupt
    impact = AssumptionImpact.where(corpus: @corpus).find(params[:id])
    impact.interrupt!(membership: Current.require_membership!)
    redirect_to workspace_corpus_assumption_impact_path(Current.workspace, @corpus, impact), notice: "Attempt interrupted; no automatic retry.", status: :see_other
  rescue CorpusIntake::Invalid => error
    redirect_to workspace_corpus_assumption_impact_path(Current.workspace, @corpus, impact), alert: error.message, status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
    end

    def prepare_preview
      @corpus.with_lock do
        raise CorpusIntake::Invalid, "Corpus sources expired; retained assumptions cannot be disclosed." if @corpus.eval_definitions_expired?
        @document_page = params[:document_page].to_i.clamp(1, 10000)
        documents = @corpus.sources.where(kind: "document")
        @document_count = documents.count
        @documents = documents.select(:id, :name).order(:id).offset((@document_page - 1) * 50).limit(50).to_a
        if params[:source_id].present?
          @source = documents.find(AssumptionChangeAnalysis.ids([ params[:source_id] ]).sole)
          @snapshot_page = params[:snapshot_page].to_i.clamp(1, 10000)
          @snapshot_count = @source.source_snapshots.count
          @snapshots = @source.source_snapshots.select(:id, :number, :created_at).order(number: :desc).offset((@snapshot_page - 1) * 50).limit(50).to_a
        end
        if params[:before_snapshot_id].present? && params[:after_snapshot_id].present?
          @version_ids = params[:version_ids].presence || AssumptionChangeAnalysis.current_version_ids(corpus: @corpus, scenario_ids: params[:scenario_ids])
          @input = AssumptionChangeAnalysis.preview(corpus: @corpus, source_id: params[:source_id], before_snapshot_id: params[:before_snapshot_id], after_snapshot_id: params[:after_snapshot_id], version_ids: @version_ids)
        end
      end
    rescue CorpusIntake::Invalid => error
      @preview_error = error.message
    end
end
