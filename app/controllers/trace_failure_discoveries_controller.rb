class TraceFailureDiscoveriesController < ApplicationController
  include WorkspaceAuthorization
  before_action :require_workspace
  before_action -> { require_role(:owner, :admin, :manager, :member) }, only: %i[new create interrupt review draft]
  before_action :load_corpus

  def index
    @page = params[:page].to_i.clamp(1, 10000)
    ids = TraceFailureDiscovery.where(corpus: @corpus).order(id: :desc).offset((@page - 1) * 20).limit(21).pluck(:id)
    @more = ids.size > 20
    @discoveries = TraceFailureDiscovery.where(id: ids.first(20)).select(:id, :corpus_id, :workspace_id, :state, :created_at).order(id: :desc)
  end

  def new
    prepare_preview
  end

  def create
    raise CorpusIntake::Invalid, "Model configuration must be JSON of at most 10 KiB." unless params[:configuration].is_a?(String) && params[:configuration].bytesize <= 10.kilobytes
    discovery = TraceFailureDiscovery.request!(corpus: @corpus, membership: Current.require_membership!, configuration: JSON.parse(params[:configuration]),
      disclose: params[:trace_discovery_disclose] == "1", input_digest: params[:input_digest])
    redirect_to discovery_path(discovery), notice: "Trace failure discovery queued. Refresh sends nothing.", status: :see_other
  rescue JSON::ParserError, CorpusIntake::Invalid, EvaluationHttp::Error, SupportOutput::Invalid => error
    prepare_preview
    flash.now[:alert] = error.is_a?(JSON::ParserError) ? "Model configuration must be valid JSON. Correct it and confirm disclosure again." : error.message
    render :new, status: :unprocessable_content
  end

  def show
    load_discovery
    prepare_result
  end

  def interrupt
    load_discovery
    @discovery.interrupt!(membership: Current.require_membership!)
    redirect_to discovery_path(@discovery), notice: "Attempt interrupted. It will not retry automatically.", status: :see_other
  rescue CorpusIntake::Invalid => error
    redirect_to discovery_path(@discovery), alert: error.message, status: :see_other
  end

  def review
    load_discovery
    item = @discovery.corpus_items.find(params[:corpus_item_id])
    TraceFailureReview.append!(discovery: @discovery, item:, membership: Current.require_membership!, decision: params[:decision], reason: params[:reason])
    redirect_to discovery_path(@discovery), notice: "Expert decision appended. No scenario, label, approval or regression was created.", status: :see_other
  rescue CorpusIntake::Invalid, ActiveRecord::RecordInvalid => error
    @review_error = error.message
    prepare_result
    render :show, status: :unprocessable_content
  end

  def draft
    load_discovery
    review = @discovery.trace_failure_reviews.find(params[:review_id])
    scenario = SupportTrace.propose!(item: review.corpus_item, membership: Current.require_membership!, discovery_review: review)
    redirect_to workspace_corpus_scenario_path(Current.workspace, @corpus, scenario), notice: "Draft opened with empty expectations. Write source-backed behaviour and review it before compilation.", status: :see_other
  rescue Scenario::Invalid, CorpusIntake::Invalid, ActiveRecord::RecordInvalid => error
    redirect_to discovery_path(@discovery), alert: error.message, status: :see_other
  end

  private
    def load_corpus
      @corpus = Current.workspace.corpora.find(params[:corpus_id])
    end

    def load_discovery
      @discovery = TraceFailureDiscovery.where(corpus: @corpus).find(params[:id])
    end

    def prepare_preview
      @input = TraceFailureDiscoveryPreview.current(@corpus).fetch(:input)
    rescue CorpusIntake::Invalid => error
      @input_error = error.message
    end

    def prepare_result
      @corpus.with_lock do
        @discovery.reload
        @expired = @discovery.expired?
        return if @expired
        begin
          @discovery.ensure_evidence!
          @stale = false
        rescue CorpusIntake::Invalid
          @stale = true
        end
        @result = @discovery.trace_failure_discovery_result&.result_content
        @input = @discovery.input_content
        @traces = @discovery.corpus_items.where(id: @input.fetch("traces").pluck("id")).includes(source_snapshot: :source).index_by(&:id)
        @reviews = @discovery.trace_failure_reviews.order(:id).to_a.group_by(&:corpus_item_id)
      end
    end

    def discovery_path(discovery)
      workspace_corpus_trace_failure_discovery_path(Current.workspace, @corpus, discovery)
    end
end
