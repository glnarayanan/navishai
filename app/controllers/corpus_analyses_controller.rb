class CorpusAnalysesController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: %i[new create update interrupt]
  before_action :load_corpus

  def new
    prepare_preview
  end

  def create
    model = params[:processing_method].in?(%w[model model_batch])
    if model
      raise CorpusIntake::Invalid, "Model configuration must be JSON of at most 10 KiB." if params[:configuration].to_s.bytesize > 10.kilobytes
      configuration = JSON.parse(params[:configuration].to_s)
      raise CorpusIntake::Invalid, "Model configuration must be a JSON object." unless configuration.is_a?(Hash)
    elsif params[:processing_method].present? && !params[:processing_method].in?(%w[local local_stream])
      raise CorpusIntake::Invalid, "Choose local, streaming local or model discovery."
    end
    analysis = CorpusAnalysis.request!(corpus: @corpus, membership: Current.require_membership!, scenario_limit: params[:scenario_limit],
      configuration:, disclose: params[:corpus_disclose] == "1", input_digest: params[:input_digest],
      processing_method: params[:processing_method], call_plan_digest: params[:call_plan_digest])
    redirect_to workspace_corpus_corpus_analysis_path(Current.workspace, @corpus, analysis), notice: "#{model ? 'Model' : 'Local'} analysis queued. Refresh never sends another request.", status: :see_other
  rescue CorpusIntake::Invalid, EvaluationHttp::Error, SupportOutput::Invalid, ActiveRecord::RecordInvalid, JSON::ParserError => error
    message = error.is_a?(JSON::ParserError) ? "Model configuration must be valid JSON. Correct it and request again." : error.message
    if params[:processing_method].in?(%w[model model_batch])
      prepare_preview
      flash.now[:alert] = message
      render :new, status: :unprocessable_content
    else
      redirect_to workspace_corpus_path(Current.workspace, @corpus), alert: "The previous local request did not start. #{message}", status: :see_other
    end
  end

  def show
    @analysis = @corpus.corpus_analyses.find(params[:id])
    raise ActiveRecord::RecordNotFound if @analysis.expired?
    @corpus.with_lock do
      groups = @analysis.selection_groups
      @family_counts = groups.transform_values(&:count)
      @family_focus = params[:family_focus].to_s.presence || "All families"
      @invalid_family_focus = !groups.key?(@family_focus)
      clusters = @invalid_family_focus ? @analysis.issue_clusters.none : groups.fetch(@family_focus)
      @page = params[:page].to_i.clamp(1, 10000)
      @clusters = clusters.order(:id).offset((@page - 1) * 10).limit(11).to_a
      @more = @clusters.size > 10
      @clusters = @clusters.first(10)
      @member_counts = ClusterMember.where(issue_cluster: @clusters).group(:issue_cluster_id).count
      @examples = @clusters.index_with { |cluster| cluster.cluster_members.order(Arel.sql("selection_reason IS NULL"), :id).limit(10).to_a }
      item_ids = @examples.values.flatten.map(&:corpus_item_id) unless @analysis.model?
      @fixed_items = @analysis.fixed_inputs(item_ids:).index_by(&:id)
      @taxonomy = @analysis.latest_taxonomy
      @model_result = @analysis.corpus_analysis_result&.result
      @model_input = ModelCorpusDiscovery.input(@fixed_items.values, bounded: !@analysis.batch?) if @analysis.model?
    end
  rescue CorpusIntake::Invalid => error
    @analysis_input_error = error.message
    render :show
  end

  def interrupt
    analysis = @corpus.corpus_analyses.find(params[:id])
    analysis.interrupt!(membership: Current.require_membership!)
    redirect_to workspace_corpus_corpus_analysis_path(Current.workspace, @corpus, analysis), notice: "Analysis interrupted. It will not retry automatically.", status: :see_other
  rescue CorpusIntake::Invalid => error
    redirect_to workspace_corpus_corpus_analysis_path(Current.workspace, @corpus, analysis), alert: error.message, status: :see_other
  end

  def update
    analysis = @corpus.corpus_analyses.find(params[:id])
    TaxonomyVersion.review!(analysis:, membership: Current.require_membership!, cluster_id: params[:cluster_id], label: params[:label])
    redirect_to workspace_corpus_corpus_analysis_path(Current.workspace, @corpus, analysis), notice: "Expert taxonomy revision saved.", status: :see_other
  rescue CorpusIntake::Invalid => error
    redirect_to workspace_corpus_corpus_analysis_path(Current.workspace, @corpus, analysis), alert: error.message, status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
    end

    def prepare_preview
      @batch = params[:processing_method] == "model_batch"
      @model_items = CorpusAnalysis.current_inputs(corpus: @corpus, model: true, batch: @batch)
      @call_plan = BatchCorpusDiscovery.plan(@model_items) if @batch
      @model_input = ModelCorpusDiscovery.input(@model_items, bounded: !@batch)
    rescue CorpusIntake::Invalid => error
      @model_input_error = error.message
    end
end
